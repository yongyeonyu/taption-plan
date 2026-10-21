import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

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
    let coordinateTimestamps: [Date]
}

private struct MapHomeCachedExpectedRouteOverlay: Codable, Sendable {
    let id: UUID
    let segmentID: UUID
    let modeRawValue: String
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [MapHomeCachedCoordinate]
}

private struct MapHomeCachedSubwayRouteOverlay: Codable, Sendable {
    let id: UUID
    let estimated: Bool
    let coordinates: [MapHomeCachedCoordinate]
    var travelID: UUID? = nil
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
    let dayProjectionRevision: UInt64
    let settingsHash: Int
    let readingsRevision: UInt64
    let nearbyPlacesRevision: UInt64
    let cutoff: Date
}

enum MapHomeTransitBoardingRefreshPolicy {
    static let interval: TimeInterval = 30

    static func shouldRefresh(lastRefresh: Date?, at date: Date) -> Bool {
        guard let lastRefresh else { return true }
        return date < lastRefresh
            || date.timeIntervalSince(lastRefresh) >= interval
    }

    static func cutoffBucket(_ date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate: floor(
                date.timeIntervalSinceReferenceDate / interval
            ) * interval
        )
    }
}

enum MapHomeTransitPOIRefreshPolicy {
    static func canStart(
        isBootstrapped: Bool,
        isSceneActive: Bool
    ) -> Bool {
        isBootstrapped && isSceneActive
    }
}

struct MapHomeDayCacheReadingsFingerprint: Codable, Equatable, Sendable {
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
    let firstTimestamp: Date?
    let lastTimestamp: Date?

    init(readings: [SensorReading]) {
        count = readings.count
        firstID = readings.first?.id
        lastID = readings.last?.id
        firstTimestamp = readings.first?.timestamp
        lastTimestamp = readings.last?.timestamp
    }
}

/// 하루 지도 캐시(파생 경로·주석·임시 위치·중심/줌)의 메모리 보관소.
/// 원본에서 다시 계산할 수 있고 Apple 지도 타일은 담지 않으므로 디스크에 저장하지 않는다.
/// 최대 14일까지만 두고 오래 안 쓴 날부터 내보내며, 메모리 경고와 데이터 삭제 때 모두 비운다.
@MainActor
private enum MapHomeDayCacheMemory {
    private struct Key: Hashable {
        let day: TaptionPlanDayKey
        let algorithmKey: String
        let styleKey: String
    }

    private struct Entry {
        let generation: UInt64
        let payload: MapHomeDayCachePayload
    }

    private static var cache = TaptionBoundedCache<Key, Entry>(capacity: 14)

    static func payload(
        day: TaptionPlanDayKey, algorithmKey: String, styleKey: String, generation: UInt64
    ) -> MapHomeDayCachePayload? {
        let key = Key(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        guard let entry = cache.value(for: key) else { return nil }
        guard entry.generation == generation else {
            cache.removeValue(for: key)
            return nil
        }
        return entry.payload
    }

    static func store(
        _ payload: MapHomeDayCachePayload,
        day: TaptionPlanDayKey, algorithmKey: String, styleKey: String, generation: UInt64
    ) {
        cache.insert(
            Entry(generation: generation, payload: payload),
            for: Key(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        )
    }

    static func removeAll() {
        cache.removeAll()
    }
}

/// 메모리 경고·데이터 삭제 때 앱 모델이 하루 지도 캐시를 비운다.
enum MapHomeDayCacheEviction {
    @MainActor static func removeAll() {
        MapHomeDayCacheMemory.removeAll()
    }
}

private struct MapHomeDayCachePayload: Codable, Sendable {
    let sourceUpdatedAt: Date?
    let sourceRevision: UInt64
    let sourceFingerprint: String?
    let readingsFingerprint: MapHomeDayCacheReadingsFingerprint?
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
        case sourceUpdatedAt, sourceRevision, sourceFingerprint
        case readingsFingerprint
        case centerLatitude, centerLongitude, latitudeDelta, longitudeDelta
        case timeline, expected, subway, subwayMinute, temporaryLocations
    }

    init(sourceUpdatedAt: Date? = nil, sourceRevision: UInt64,
         sourceFingerprint: String? = nil,
         readingsFingerprint: MapHomeDayCacheReadingsFingerprint? = nil,
         centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double,
         timeline: [MapHomeCachedRouteOverlay], expected: [MapHomeCachedExpectedRouteOverlay]?,
         subway: [MapHomeCachedSubwayRouteOverlay]?, subwayMinute: Int?,
         temporaryLocations: [MapHomeCachedTemporaryLocation]? = nil) {
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sourceRevision = sourceRevision
        self.sourceFingerprint = sourceFingerprint
        self.readingsFingerprint = readingsFingerprint
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
        sourceUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt)
        sourceRevision = try container.decode(UInt64.self, forKey: .sourceRevision)
        sourceFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .sourceFingerprint
        )
        readingsFingerprint = try container.decodeIfPresent(
            MapHomeDayCacheReadingsFingerprint.self,
            forKey: .readingsFingerprint
        )
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

    func reset() {
        needsRefresh = false
        needsReadingPreparation = false
    }
}

private struct MapHomeRouteCoordinateBounds {
    var minLatitude = CLLocationDegrees.greatestFiniteMagnitude
    var maxLatitude = -CLLocationDegrees.greatestFiniteMagnitude
    var minLongitude = CLLocationDegrees.greatestFiniteMagnitude
    var maxLongitude = -CLLocationDegrees.greatestFiniteMagnitude
    private var longitudeOrigin: CLLocationDegrees?

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
            let origin = longitudeOrigin ?? coordinate.longitude
            longitudeOrigin = origin
            let longitude = origin + RouteTimelineLongitude.shortestDelta(
                from: origin,
                to: coordinate.longitude
            )
            minLongitude = min(minLongitude, longitude)
            maxLongitude = max(maxLongitude, longitude)
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
        let latitudeDelta = max(
            minimumLatitudeDelta,
            (latitudes.max()! - latitudes.min()!) * padding
        )
        let origin = valid[0].longitude
        let unwrappedLongitudes = valid.map {
            origin + RouteTimelineLongitude.shortestDelta(
                from: origin,
                to: $0.longitude
            )
        }
        let longitudeDelta = max(
            minimumLongitudeDelta,
            (unwrappedLongitudes.max()! - unwrappedLongitudes.min()!) * padding
        )
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudes.max()! + latitudes.min()!) / 2,
                longitude: RouteTimelineLongitude.normalized(
                    (unwrappedLongitudes.max()! + unwrappedLongitudes.min()!) / 2
                )
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }
}

private final class MapHomeMapRenderCache {
    private let subway = MapHomeSubwayRouteCache()
    private(set) var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay]?
    private(set) var visibleExpectedRouteCutoff: Date?
    private(set) var routeBounds: MapHomeRouteCoordinateBounds?
    private var transitBoardingCandidateCache:
        (key: MapHomeTransitBoardingCandidateCacheKey, candidates: [TransitBoardingCandidate])?
    private var gradientSliceCache: [String: (key: Int, slices: [MapHomeRouteGradientSlice]?)] = [:]
    private static let gradientSliceCacheLimit = 32

    /// 경로의 속도 그라데이션 구간. 지오메트리 서명과 시각이 같으면 다시 계산하지 않는다.
    func gradientSlices(
        id: String,
        coordinates: [CLLocationCoordinate2D],
        geometrySignature: Int,
        timestamps: [Date]
    ) -> [MapHomeRouteGradientSlice]? {
        var hasher = Hasher()
        hasher.combine(geometrySignature)
        hasher.combine(timestamps.count)
        hasher.combine(timestamps.first)
        hasher.combine(timestamps.last)
        let key = hasher.finalize()
        if let cached = gradientSliceCache[id], cached.key == key {
            return cached.slices
        }
        let slices = MapHomeRouteGradientSlicer.slices(
            overlayID: id,
            coordinates: coordinates,
            timestamps: timestamps
        )
        if gradientSliceCache.count >= Self.gradientSliceCacheLimit {
            gradientSliceCache.removeAll(keepingCapacity: true)
        }
        gradientSliceCache[id] = (key, slices)
        return slices
    }

    func invalidateRouteData() {
        gradientSliceCache.removeAll(keepingCapacity: true)
        subway.invalidate()
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
        subway.restore(day: day, overlays: overlays)
        routeBounds = nil
    }

    func subwayRoutes(
        day: Date,
        minute: Int,
        sourceRevision: UInt64?,
        make: () -> [MapHomeSubwayRouteOverlay]
    ) -> [MapHomeSubwayRouteOverlay] {
        subway.routes(day: day, minute: minute, sourceRevision: sourceRevision) {
            routeBounds = nil
            return make()
        }
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
    static let sharedBottomMargin: CGFloat = 48
    static let maximumRailHeight: CGFloat = 680

    static func alignedRailFrame(
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGRect {
        let height = max(0, viewportHeight)
        let top = min(max(0, topInset), height)
        let bottom = min(max(0, bottomInset), height - top)
        let availableHeight = height - top - bottom
        let railHeight = min(maximumRailHeight, availableHeight)
        return CGRect(
            x: 0,
            y: top + availableHeight - railHeight,
            width: 0,
            height: railHeight
        )
    }

    static func timeSidebarFrame(
        viewportHeight: CGFloat,
        topOverlayHeight: CGFloat,
        topMargin: CGFloat = 20,
        bottomMargin: CGFloat = 32
    ) -> CGRect {
        let height = max(0, viewportHeight)
        let top = min(max(0, topOverlayHeight + topMargin), height)
        let bottom = min(max(0, bottomMargin), height - top)
        let availableHeight = height - top - bottom
        let railHeight = timeSidebarHeight(availableHeight: availableHeight)
        return CGRect(
            x: 0,
            y: top + availableHeight - railHeight,
            width: 0,
            height: railHeight
        )
    }

    static func timeSidebarHeight(availableHeight: CGFloat) -> CGFloat {
        max(0, availableHeight)
    }

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
    static let scalePerStep: CGFloat = 1.10
    static let maximumStepOffset = 4

    static func stepOffset(magnification: CGFloat) -> Int {
        guard magnification.isFinite, magnification > 0 else { return 0 }
        let raw = log(Double(magnification)) / log(Double(scalePerStep))
        let offset = raw >= 0 ? Int(floor(raw)) : Int(ceil(raw))
        return min(max(offset, -maximumStepOffset), maximumStepOffset)
    }
}

private enum MapHomeForecastRouteDisplayPolicy {
    static let maximumVisibleRoutes = 8
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
    /// 재생 틱은 120Hz 예산(대표 지시, PLY1020R01). 60Hz 기기는 시스템이 프레임을 합친다.
    static let frameIntervalNanoseconds: UInt64 = 8_333_333
    static let routeProjectionInterval: TimeInterval = 0.25
    /// 8ms 문턱: 8.33ms 틱의 지터에도 매 프레임 지도 중심을 갱신한다.
    static let mapFocusInterval: TimeInterval = 0.008
    /// 정지 구간(업무·수면·활동 등)은 초당 120분으로 지나간다(대표 지시, PLY1020W01).
    static let stationaryMinutesPerSecond = 120.0
    /// 이동 구간은 정지 구간 배속의 1/24(초당 2.5분)로 재생한다. 이전 1/6보다 4배 느리다(대표 지시, PLY1020C01).
    static let movementPlaybackMultiplier = 1.0 / 48.0
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
        isPlaybackRunning: Bool,
        interactiveProjectionCutoff: Date? = nil
    ) -> Date {
        let candidate = isPlaybackRunning
            ? timelineDate
            : interactiveProjectionCutoff ?? timelineDate
        return min(selectedDayEnd, candidate)
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
        case .walking:
            // 걷기는 다른 이동보다 두 배 빠르게 재생한다(대표 지시, PLY1020Z01).
            return MapHomeDayPlaybackMath.movingMinutesPerSecond * 2
        case .running, nil:
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
    static let fullDayTemperatureChangeCelsius = 2

    static func context(
        at date: Date,
        contexts: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent
    ) -> WeatherContext? {
        displayContexts(contexts, calendar: calendar)
            .filter { $0.observedAt <= date }
            .max { $0.observedAt < $1.observedAt }
    }

    static func persistentSpans(
        for date: Date,
        contexts: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent,
        minimumTemperatureChangeCelsius: Int = 0
    ) -> [(context: WeatherContext, span: TimeSpan)] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let ordered = displayContexts(contexts, calendar: calendar)
        var displayRuns: [(context: WeatherContext, start: Date)] = []
        var lastDisplayedContext: WeatherContext?

        for context in ordered {
            guard let lastIndex = displayRuns.indices.last else {
                displayRuns.append((context: context, start: context.observedAt))
                lastDisplayedContext = context
                continue
            }
            if !startsNewDisplayRun(
                from: lastDisplayedContext ?? displayRuns[lastIndex].context,
                to: context,
                minimumTemperatureChangeCelsius: minimumTemperatureChangeCelsius
            ) {
                if minimumTemperatureChangeCelsius == 0 {
                    displayRuns[lastIndex].context = context
                }
            } else {
                displayRuns.append((context: context, start: context.observedAt))
                lastDisplayedContext = context
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

    private static func displayContexts(
        _ contexts: [WeatherContext],
        calendar: Calendar
    ) -> [WeatherContext] {
        let ordered = coalescedDisplayContexts(contexts).sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            if ($0.isForecast == true) != ($1.isForecast == true) {
                return $0.isForecast != true
            }
            if $0.fetchedAt != $1.fetchedAt {
                return ($0.fetchedAt ?? .distantPast)
                    < ($1.fetchedAt ?? .distantPast)
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [(bucket: Date, context: WeatherContext)] = []
        result.reserveCapacity(ordered.count)
        for context in ordered {
            let bucket = calendar.dateInterval(
                of: .minute,
                for: context.observedAt
            )?.start ?? context.observedAt
            guard let lastIndex = result.indices.last,
                  result[lastIndex].bucket == bucket else {
                result.append((bucket: bucket, context: context))
                continue
            }
            let current = result[lastIndex].context
            if prefersForDisplay(context, over: current) {
                result[lastIndex].context = context
            }
        }
        return result.map(\.context)
    }

    static func coalescedDisplayContexts(
        _ contexts: [WeatherContext]
    ) -> [WeatherContext] {
        (
            WeatherTimelineEngine.coalesced(
                contexts.filter { $0.isForecast != true }
            )
            + WeatherTimelineEngine.coalesced(
                contexts.filter { $0.isForecast == true }
            )
        ).sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            if ($0.isForecast == true) != ($1.isForecast == true) {
                return $0.isForecast != true
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func prefersForDisplay(
        _ candidate: WeatherContext,
        over current: WeatherContext
    ) -> Bool {
        if ((candidate.isForecast == true) != (current.isForecast == true)) {
            return candidate.isForecast != true
        }
        if candidate.observedAt != current.observedAt {
            return candidate.observedAt > current.observedAt
        }
        if candidate.fetchedAt != current.fetchedAt {
            return (candidate.fetchedAt ?? .distantPast)
                > (current.fetchedAt ?? .distantPast)
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    private static func startsNewDisplayRun(
        from previous: WeatherContext,
        to current: WeatherContext,
        minimumTemperatureChangeCelsius: Int
    ) -> Bool {
        guard previous.symbolName == current.symbolName else { return true }

        let previousTemperature = Int(previous.temperatureCelsius.rounded())
        let currentTemperature = Int(current.temperatureCelsius.rounded())
        let temperatureChange = abs(currentTemperature - previousTemperature)
        if minimumTemperatureChangeCelsius > 0 {
            return temperatureChange >= minimumTemperatureChangeCelsius
        }
        return temperatureChange != 0
    }
}

enum MapHomeWeatherDisplayCache {
    static func merged(
        cached: [WeatherContext],
        incoming: [WeatherContext]
    ) -> [WeatherContext] {
        let fresh = incoming.filter(MapHomeWeatherDisplayPolicy.isComplete)
        guard !fresh.isEmpty else { return cached }
        return Array(MapHomeWeatherTimelineMath.coalescedDisplayContexts(
            cached + fresh
        ).suffix(maximumContexts))
    }

    private static let maximumContexts = 512

    static func contexts(
        incoming: [WeatherContext],
        cached: [WeatherContext]
    ) -> [WeatherContext] {
        let merged = merged(cached: cached, incoming: incoming)
        return merged.isEmpty ? incoming : merged
    }
}

@MainActor
enum MapHomeCameraLogThrottle {
    private static var lastUptime: TimeInterval = 0

    static func shouldLog(nowUptime: TimeInterval, interval: TimeInterval = 1) -> Bool {
        guard nowUptime - lastUptime >= interval else { return false }
        lastUptime = nowUptime
        return true
    }
}

/// body마다 여러 번 읽히는 사진 묶음을 (사진 목록, 반경)이 같으면 재사용한다.
@MainActor
final class MapHomePhotoClusterCache {
    private var key: Int?
    private var value: [MapHomePhotoCluster] = []

    func clusters(for moments: [PhotoMoment], radiusMeters: Double) -> [MapHomePhotoCluster] {
        var hasher = Hasher()
        hasher.combine(radiusMeters)
        for moment in moments {
            hasher.combine(moment.id)
            hasher.combine(moment.location?.latitude)
            hasher.combine(moment.location?.longitude)
        }
        let next = hasher.finalize()
        if key == next { return value }
        value = MapHomePhotoPolicy.clusters(from: moments, radiusMeters: radiusMeters)
        key = next
        return value
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

    static func focusesLocationUpdates(in mode: MapHomeUserTrackingMode) -> Bool {
        mode == .following
    }

    static func isSingleFingerPanStart(
        state: UIGestureRecognizer.State,
        numberOfTouches: Int
    ) -> Bool {
        (state == .began || state == .changed) && numberOfTouches == 1
    }
}

enum MapHomePlacePinLayout {
    /// 집 핀의 레벨 라벨 높이. 위쪽에 같은 높이를 비워 아이콘 위치를 유지한다.
    static let levelLabelHeight: CGFloat = 22
    /// Apple 지도 호스팅 뷰의 집 핀 높이: 기존 138 + 위아래 (라벨 높이 + 간격 5) 두 번.
    static let appleHomeHostHeight: CGFloat = 138 + 2 * (levelLabelHeight + 5)
}

enum MapHomePlaceAnnotationLayout {
    static let vectorAnchor = UnitPoint.center
    static let appleCenterOffset = CGPoint.zero
}

/// 일정 메모 미리보기: 사이드바 시각이 메모 시각의 앞뒤 30분 안에 오면 보여 준다(대표 선택).
enum MapHomeMemoPreviewPolicy {
    static let windowSeconds: TimeInterval = 30 * 60

    /// 선택한 날짜의 일정 메모 중 `now` 앞뒤 30분 안에서 가장 가까운 것(닫은 것은 제외). 없으면 nil.
    static func nearest(
        in stickers: [MapSticker],
        at now: Date,
        selectedDate: Date,
        dismissed: Set<UUID> = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapSticker? {
        stickers
            .filter {
                $0.placement == .schedule
                    && !dismissed.contains($0.id)
                    && calendar.isDate($0.occurredAt, inSameDayAs: selectedDate)
                    && abs($0.occurredAt.timeIntervalSince(now)) <= windowSeconds
            }
            .min { abs($0.occurredAt.timeIntervalSince(now)) < abs($1.occurredAt.timeIntervalSince(now)) }
    }
}

enum MapHomeStickmanAnnotationLayout {
    static let centerOffset = CGPoint(x: 0, y: -18)
}

enum MapHomePresencePolicy {
    static func isAtHome(
        current: CLLocationCoordinate2D,
        home: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) -> Bool {
        guard valid(current), valid(home), radiusMeters.isFinite,
              radiusMeters >= 0 else { return false }
        return CLLocation(latitude: current.latitude, longitude: current.longitude)
            .distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
            <= radiusMeters
    }

    private static func valid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

/// 정지 상태 확대용 2초 간격 신호. body마다 새로 만들면 다시 구독돼 멈추므로 하나를 공유한다.
@MainActor private let mapHomeStationaryZoomTicker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

/// 지도 거리 기준(배율 0~100, 대표 지시 ZMP1020A01). 정지·걷기·등록 장소에서 이어지는 이동·시작 화면은 85로 고정하고,
/// 그 밖의 탈것만 속도에 따라 느리면 92(약 220m)까지 확대, 빠르면 42(약 140km)까지 축소한다.
enum MapHomePlaybackZoomPolicy {
    static let baselineScale = 85.0
    static let slowestScale = 92.0
    static let fastestScale = 30.0
    /// 이 속도(m/s)에서 `slowestScale`, `vehicleSpeed`에서 `fastestScale`(로그 비율).
    static let slowSpeed = 1.0
    static let vehicleSpeed = 40.0
    /// 센서 속도만 아는 경우 이 속도 이하는 걷기 이하로 보고 85에 고정한다.
    static let walkingCeiling = 2.5
    static let easing = 0.2

    static var baselineDistance: Double { MapHomeCameraZoomMath.distance(forScale: baselineScale) }

    /// 탈것의 속도에 맞는 배율(로그 비율, 범위 안으로 자른다).
    static func scale(forVehicleSpeed speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return slowestScale }
        let clamped = min(vehicleSpeed, max(slowSpeed, speed))
        let ratio = (log(clamped) - log(slowSpeed)) / (log(vehicleSpeed) - log(slowSpeed))
        return slowestScale + ratio * (fastestScale - slowestScale)
    }

    /// 센서 속도만 아는 때(실시간 따라가기)의 목표 거리. 걷기 이하·정지는 85, 그 위는 탈것 곡선. 모르면 nil.
    static func targetDistance(speedMetersPerSecond: Double?) -> Double? {
        guard let speed = speedMetersPerSecond, speed.isFinite, speed >= 0 else { return nil }
        guard speed > walkingCeiling else { return baselineDistance }
        return MapHomeCameraZoomMath.distance(forScale: scale(forVehicleSpeed: speed))
    }

    /// 경로 범위(대각선 m)가 한 화면에 들어오는 배율. 카메라 거리는 보이는 범위의 약 1.9배(시야각)에 여유 1.3을 곱해 정하고,
    /// 너무 넓거나(15 미만) 좁지 않게(60 초과 없음) 자른다.
    static func fitScale(forExtentMeters extent: Double) -> Double {
        guard extent.isFinite, extent > 0,
              let scale = MapHomeCameraZoomMath.scale(distance: extent * 2.43) else { return fastestScale }
        return min(60, max(15, Double(scale)))
    }

    static func eased(current: Double, target: Double) -> Double {
        exp(log(current) + (log(target) - log(current)) * easing)
    }
}

/// 지도에 쓰인 점 중 가장 크게 튄 구간을 좌표 없이 요약해 로그로 남긴다.
enum MapHomeRouteJumpDiagnostics {
    static func fields(for readings: [SensorReading], calendar: Calendar = .autoupdatingCurrent) -> [String: String] {
        let sorted = readings
            .filter { $0.point != nil }
            .sorted { $0.timestamp < $1.timestamp }
        var best: (meters: Double, gap: TimeInterval, later: SensorReading)?
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            guard let from = earlier.point, let to = later.point else { continue }
            let meters = distanceMeters(from, to)
            if best == nil || meters > best!.meters {
                best = (meters, later.timestamp.timeIntervalSince(earlier.timestamp), later)
            }
        }
        guard let best else { return [:] }
        let parts = calendar.dateComponents([.hour, .minute], from: best.later.timestamp)
        return [
            "largest_jump_m": String(Int(best.meters.rounded())),
            "largest_jump_gap_s": String(Int(best.gap.rounded())),
            "largest_jump_speed_mps": best.gap > 0 ? String(Int((best.meters / best.gap).rounded())) : "0",
            "largest_jump_at": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0),
            "largest_jump_quality": best.later.locationFixQuality?.rawValue ?? "unknown",
            "largest_jump_device": best.later.sourceDevice?.rawValue ?? "unknown",
            "largest_jump_accuracy_m": best.later.point.map { String(Int($0.horizontalAccuracy.rounded())) } ?? "unknown",
        ]
    }
}

/// 예상 경로 중 양 끝이 가장 멀리 떨어진 것을 좌표 없이 요약한다.
/// 직선처럼 먼 예상 경로가 어디서 생겼는지(종류·수단·시각) 로그로 가려내기 위함이다.
enum MapHomeExpectedRouteDiagnostics {
    struct Candidate {
        let kind: String
        let mode: String
        let start: Date
        let end: Date
        let first: CLLocationCoordinate2D
        let last: CLLocationCoordinate2D
    }

    static func fields(
        for candidates: [Candidate],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: String] {
        var best: (Candidate, Double)?
        for candidate in candidates {
            let meters = CLLocation(latitude: candidate.first.latitude, longitude: candidate.first.longitude)
                .distance(from: CLLocation(latitude: candidate.last.latitude, longitude: candidate.last.longitude))
            guard meters.isFinite else { continue }
            if best == nil || meters > best!.1 { best = (candidate, meters) }
        }
        guard let (candidate, meters) = best else { return [:] }
        func clock(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return [
            "longest_route_kind": candidate.kind,
            "longest_route_mode": candidate.mode,
            "longest_route_km": String(Int((meters / 1_000).rounded())),
            "longest_route_start": clock(candidate.start),
            "longest_route_end": clock(candidate.end),
            "longest_route_minutes": String(Int(candidate.end.timeIntervalSince(candidate.start) / 60)),
        ]
    }
}

/// 발바닥 색: 느리면 빨강, 중간 속도는 초록, 빠르면 파랑(시속 150km에서 최대)으로 같은 비율로 나눈다. 속도를 모르는 미확인은 회색.
enum MapHomePawprintSpeedColor {
    static let maximumMetersPerSecond = 150.0 / 3.6

    static func ratio(forMetersPerSecond speed: Double?) -> Double? {
        guard let speed, speed.isFinite, speed >= 0 else { return nil }
        return min(1, speed / maximumMetersPerSecond)
    }

    static func color(forMetersPerSecond speed: Double?) -> Color {
        guard let ratio = ratio(forMetersPerSecond: speed) else {
            return Color.gray.opacity(0.68)
        }
        // 색상환 빨강(0) → 초록(1/3) → 파랑(2/3)을 속도 비율 0~1에 고르게 대응시킨다.
        return Color(hue: (2.0 / 3.0) * ratio, saturation: 0.85, brightness: 0.82)
            .opacity(0.9)
    }

    /// 발자국 색 속도: 해당 점 앞뒤 `halfWindow`초 구간의 이동거리/시간. 인접 두 점의 순간 속도는
    /// GPS 잡음으로 튀고, 재생으로 발자국이 다시 뽑힐 때마다 색이 바뀌므로 시간 창으로 고정한다.
    static let windowSeconds: TimeInterval = 30

    static func windowedSpeed(
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date],
        index: Int,
        halfWindow: TimeInterval = windowSeconds
    ) -> Double? {
        guard coordinates.count == timestamps.count, coordinates.indices.contains(index),
              halfWindow > 0 else { return nil }
        let center = timestamps[index]
        var low = index
        while low > 0, center.timeIntervalSince(timestamps[low - 1]) <= halfWindow { low -= 1 }
        var high = index
        while high < coordinates.count - 1, timestamps[high + 1].timeIntervalSince(center) <= halfWindow {
            high += 1
        }
        guard high > low else { return nil }
        let seconds = timestamps[high].timeIntervalSince(timestamps[low])
        guard seconds > 0 else { return nil }
        var meters = 0.0
        for k in low..<high {
            meters += CLLocation(latitude: coordinates[k].latitude, longitude: coordinates[k].longitude)
                .distance(from: CLLocation(latitude: coordinates[k + 1].latitude, longitude: coordinates[k + 1].longitude))
        }
        return meters / seconds
    }

    static func speed(
        from first: CLLocationCoordinate2D,
        at firstDate: Date?,
        to second: CLLocationCoordinate2D,
        at secondDate: Date?
    ) -> Double? {
        guard let firstDate, let secondDate else { return nil }
        let seconds = secondDate.timeIntervalSince(firstDate)
        guard seconds > 0 else { return nil }
        let meters = CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
        return meters / seconds
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

enum MapHomePlaybackCenterPolicy {
    static func shouldCenter(
        previousCoordinate: CLLocationCoordinate2D?,
        previousTargetPoint: CGPoint?,
        coordinate: CLLocationCoordinate2D,
        targetPoint: CGPoint,
        hasPendingViewportCommand: Bool = false
    ) -> Bool {
        guard !hasPendingViewportCommand else { return false }
        guard let previousCoordinate, let previousTargetPoint else {
            return true
        }
        return abs(previousCoordinate.latitude - coordinate.latitude) > 0.000_001
            || abs(previousCoordinate.longitude - coordinate.longitude) > 0.000_001
            || hypot(
                previousTargetPoint.x - targetPoint.x,
                previousTargetPoint.y - targetPoint.y
            ) > 0.5
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
        for reading in existing where RouteTimelineTimestamp.isValid(reading.timestamp)
            && span.contains(reading.timestamp) {
            readingsByID[reading.id] = reading
        }
        for reading in loaded where RouteTimelineTimestamp.isValid(reading.timestamp)
            && span.contains(reading.timestamp) {
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

struct MapHomePredictedRouteCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct MapHomePredictedGPSGap {
    let start: SensorReading
    let end: SensorReading
    let coordinates: [MapHomePredictedRouteCoordinate]
}

enum MapHomeGPSGapPredictionPolicy {
    static let minimumGap: TimeInterval = 45
    static let maximumGap: TimeInterval = 5 * 60
    static let maximumDistanceMeters = 600.0
    static let maximumEndpointAccuracyMeters = 50.0
    static let maximumAverageSpeedMetersPerSecond = 3.0
    static let sampleSpacingMeters = 25.0
    static let maximumSamplesPerGap = 24

    static func predictedRailCoordinates(
        from overlays: [MapHomeSubwayRouteOverlay]
    ) -> [[MapHomePredictedRouteCoordinate]] {
        let paths = overlays.map { predictedRailCoordinates(along: $0.coordinates) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        let budget = 96
        let samplesPerPath = budget / paths.count
        let remainder = budget % paths.count
        return paths.enumerated().compactMap { index, points in
            let count = min(points.count, samplesPerPath + (index < remainder ? 1 : 0))
            guard count > 0 else { return nil }
            if count == 1 { return [points[points.count / 2]] }
            return (0..<count).map { sample in
                points[sample * (points.count - 1) / (count - 1)]
            }
        }
    }

    static func predictedCoordinates(
        from readings: [SensorReading],
        through cutoff: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [[MapHomePredictedRouteCoordinate]] {
        predictedGaps(from: readings, through: cutoff, calendar: calendar).map(\.coordinates)
    }

    static func predictedGaps(
        from readings: [SensorReading],
        through cutoff: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomePredictedGPSGap] {
        let ordered = readings.filter { reading in
            RouteTimelineTimestamp.isValid(reading.timestamp)
                && (cutoff.map { reading.timestamp <= $0 } ?? true)
        }.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }

        var pairs: [(SensorReading, SensorReading)] = []
        var previousFix: SensorReading?
        for reading in ordered {
            if reading.trackingSessionEnded == true || reading.sourceDevice == .appleWatch {
                previousFix = nil
                continue
            }
            guard isEligibleFix(reading) else { continue }
            if let previousFix { pairs.append((previousFix, reading)) }
            previousFix = reading
        }
        return pairs.compactMap { pair in
            let (start, end) = pair
            guard Self.isEligibleFix(start), Self.isEligibleFix(end),
                  let startPoint = start.point,
                  let endPoint = end.point else { return nil }
            let duration = end.timestamp.timeIntervalSince(start.timestamp)
            guard duration >= minimumGap,
                  duration <= maximumGap,
                  calendar.isDate(start.timestamp, inSameDayAs: end.timestamp) else {
                return nil
            }
            let distance = CLLocation(
                latitude: startPoint.latitude,
                longitude: startPoint.longitude
            ).distance(from: CLLocation(
                latitude: endPoint.latitude,
                longitude: endPoint.longitude
            ))
            guard distance >= sampleSpacingMeters,
                  distance <= maximumDistanceMeters,
                  distance / duration <= maximumAverageSpeedMetersPerSecond else {
                return nil
            }
            let sampleCount = min(
                maximumSamplesPerGap,
                max(1, Int(ceil(distance / sampleSpacingMeters)) - 1)
            )
            let coordinates = (1...sampleCount).map { index in
                let fraction = Double(index) / Double(sampleCount + 1)
                return MapHomePredictedRouteCoordinate(
                    latitude: startPoint.latitude
                        + (endPoint.latitude - startPoint.latitude) * fraction,
                    longitude: startPoint.longitude
                        + (endPoint.longitude - startPoint.longitude) * fraction
                )
            }
            return MapHomePredictedGPSGap(start: start, end: end, coordinates: coordinates)
        }
    }

    static func predictedRailCoordinates(
        along coordinates: [CLLocationCoordinate2D]
    ) -> [MapHomePredictedRouteCoordinate] {
        guard coordinates.count >= 2,
              coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else { return [] }
        let lengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(for: coordinates)
        let distance = lengths.reduce(0, +)
        guard distance.isFinite, distance >= sampleSpacingMeters else { return [] }
        let count = min(maximumSamplesPerGap, max(2, Int(ceil(distance / sampleSpacingMeters))))
        return (0..<count).compactMap { index in
            guard let point = MapHomeExpectedRoutePlaybackMath.coordinate(
                atProgress: Double(index) / Double(count - 1),
                coordinates: coordinates, segmentLengths: lengths
            ) else { return nil }
            return MapHomePredictedRouteCoordinate(latitude: point.latitude, longitude: point.longitude)
        }
    }

    private static func isEligibleFix(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable,
              reading.locationFixQuality != .approximate,
              reading.sourceDevice != .appleWatch,
              reading.trackingSessionEnded != true,
              let point = reading.point,
              point.latitude.isFinite, (-90...90).contains(point.latitude),
              point.longitude.isFinite, (-180...180).contains(point.longitude),
              point.horizontalAccuracy.isFinite,
              point.horizontalAccuracy >= 0,
              point.horizontalAccuracy <= maximumEndpointAccuracyMeters else {
            return false
        }
        return true
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
    let rawDataRevision: UInt64
    let isSceneActive: Bool

    init(
        date: Date,
        isBootstrapped: Bool,
        rawDataRevision: UInt64 = 0,
        isSceneActive: Bool = true,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        day = calendar.startOfDay(for: date)
        self.isBootstrapped = isBootstrapped
        self.rawDataRevision = rawDataRevision
        self.isSceneActive = isSceneActive
    }
}

struct MapHomeDaySourceTaskKey: Hashable {
    let day: Date
    let revision: UInt64
    let isReady: Bool
    let isActive: Bool
}

struct MapHomePreparedRouteReadings: Sendable {
    let normalized: [SensorReading]
    let display: [SensorReading]
    let latestTrustedReading: SensorReading?
    let impossibleLocationCount: Int
    let innovationOutlierCount: Int
    let sourceCount: Int
    let filteredCount: Int
    let watchSourceCount: Int
    let readingsWithPointCount: Int
    let railMatchCount: Int
    let stationNameCount: Int
}

enum MapHomeRouteReadingsPreparation {
    static func latestRouteInputSignature(
        _ reading: SensorReading?
    ) -> String {
        guard let reading else { return "none" }
        let point = reading.point.map {
            [
                String($0.latitude),
                String($0.longitude),
                String($0.altitude),
                String($0.horizontalAccuracy),
                String($0.verticalAccuracy),
            ].joined(separator: ",")
        } ?? "none"
        return [
            reading.id.uuidString,
            String(reading.timestamp.timeIntervalSinceReferenceDate),
            point,
            reading.gpsAvailable ? "gps" : "approximate",
            reading.locationFixQuality?.rawValue ?? "unspecified",
            reading.speedMetersPerSecond.map { String($0) } ?? "none",
            reading.speedAccuracyMetersPerSecond.map { String($0) } ?? "none",
            reading.courseDegrees.map { String($0) } ?? "none",
            reading.courseAccuracyDegrees.map { String($0) } ?? "none",
            reading.motion.rawValue,
            reading.sequence.map { String($0) } ?? "none",
            reading.sourceDevice?.rawValue ?? "none",
            reading.trackingSessionEnded == true
                ? "session-ended"
                : "session-open",
        ].joined(separator: "|")
    }

    static func prepare(
        routeReadings: [SensorReading],
        liveReadings: [SensorReading],
        latestReading: SensorReading?,
        dayStart: Date,
        dayEnd: Date,
        cancellationCheck: () throws -> Void
    ) throws -> MapHomePreparedRouteReadings {
        try cancellationCheck()
        let sourceCount = routeReadings.count + liveReadings.count
            + (latestReading == nil ? 0 : 1)
        var dayReadings: [SensorReading] = []
        dayReadings.reserveCapacity(sourceCount)
        var watchSourceCount = 0
        for readings in [routeReadings, liveReadings] {
            for (index, reading) in readings.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                if reading.sourceDevice == .appleWatch {
                    watchSourceCount += 1
                }
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      reading.timestamp >= dayStart,
                      reading.timestamp < dayEnd else { continue }
                dayReadings.append(reading)
            }
        }
        if let latestReading {
            if latestReading.sourceDevice == .appleWatch {
                watchSourceCount += 1
            }
            if RouteTimelineTimestamp.isValid(latestReading.timestamp),
               latestReading.timestamp >= dayStart,
               latestReading.timestamp < dayEnd {
                dayReadings.append(latestReading)
            }
        }
        let filteredRoute = try TaptionRouteEngineAdapter.prepareFilteredReadings(
            from: dayReadings,
            cancellationCheck: cancellationCheck
        )
        let filtered = filteredRoute.readings
        try cancellationCheck()
        let normalized = try RouteTimelineDataEngine
            .normalizedDisplayReadings(
                filtered,
                cancellationCheck: cancellationCheck
            )
        try cancellationCheck()
        let display = try RouteTimelineDataEngine.displayReadings(
            from: normalized,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        var readingsWithPointCount = 0
        var railMatchCount = 0
        var stationNames = Set<String>()
        for (index, reading) in normalized.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if reading.point != nil { readingsWithPointCount += 1 }
            if reading.matchesRailRoute { railMatchCount += 1 }
            if let name = reading.nearbyStationName { stationNames.insert(name) }
        }
        try cancellationCheck()
        return MapHomePreparedRouteReadings(
            normalized: normalized,
            display: display,
            latestTrustedReading: filteredRoute.latestTrustedReading,
            impossibleLocationCount: filteredRoute.impossibleLocationCount,
            innovationOutlierCount: filteredRoute.innovationOutlierCount,
            sourceCount: sourceCount,
            filteredCount: filtered.count,
            watchSourceCount: watchSourceCount,
            readingsWithPointCount: readingsWithPointCount,
            railMatchCount: railMatchCount,
            stationNameCount: stationNames.count
        )
    }
}

struct MapHomeRouteReadingsPreparationGeneration: Sendable {
    private(set) var currentID = UUID()

    @discardableResult
    mutating func advance() -> UUID {
        currentID = UUID()
        return currentID
    }

    func accepts(_ preparationID: UUID) -> Bool {
        currentID == preparationID
    }
}

struct MapHomeGrowthSeason: Codable, Equatable {
    var year: Int
    var level = 1
    var streak = 0
    var lastClosedDay: String?
    var pendingDay: String?
    var pendingDayQualified = false
    var pendingWeeklyRewards = 0
    var chosenEvolutions: [String] = []
    var landPlots: [String] = []
    var accessories: [String] = []
    var equippedAccessory: String?
    var landPlotPlacements: [MapHomeGrowthPlotPlacement]?
    var recentCompletionRewardedDays: [String]?
}

extension MapHomeGrowthSeason {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
            ?? Calendar(identifier: .gregorian).component(.year, from: .now)
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastClosedDay = try c.decodeIfPresent(String.self, forKey: .lastClosedDay)
        pendingDay = try c.decodeIfPresent(String.self, forKey: .pendingDay)
        pendingDayQualified = try c.decodeIfPresent(Bool.self, forKey: .pendingDayQualified) ?? false
        pendingWeeklyRewards = try c.decodeIfPresent(Int.self, forKey: .pendingWeeklyRewards) ?? 0
        chosenEvolutions = try c.decodeIfPresent([String].self, forKey: .chosenEvolutions) ?? []
        landPlots = try c.decodeIfPresent([String].self, forKey: .landPlots) ?? []
        accessories = try c.decodeIfPresent([String].self, forKey: .accessories) ?? []
        equippedAccessory = try c.decodeIfPresent(String.self, forKey: .equippedAccessory)
        landPlotPlacements = try c.decodeIfPresent([MapHomeGrowthPlotPlacement].self, forKey: .landPlotPlacements)
        recentCompletionRewardedDays = try c.decodeIfPresent([String].self, forKey: .recentCompletionRewardedDays)
    }
}

struct MapHomeGrowthPlotPlacement: Codable, Equatable, Identifiable {
    let plotID: String
    let x: Int
    let y: Int

    var id: String { plotID }
}

struct MapHomeLandmarkCandidate: Identifiable, Equatable {
    let id: String
    let country: String
    let name: String
    let englishName: String
    let category: String
    let systemImage: String

    var artworkName: String {
        "Landmark_" + id.replacingOccurrences(of: ".", with: "_")
    }

    var accessoryID: String { "cat.accessory.\(id)" }
}

enum MapHomeLandmarkCatalog {
    static let candidates: [MapHomeLandmarkCandidate] = [
        .init(id: "kr.gyeongbokgung", country: "대한민국", name: "경복궁", englishName: "Gyeongbokgung", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "kr.bulguksa", country: "대한민국", name: "불국사", englishName: "Bulguksa", category: "문화", systemImage: "building.2.fill"),
        .init(id: "kr.seongsan", country: "대한민국", name: "성산일출봉", englishName: "Seongsan Ilchulbong", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "kr.haeundae", country: "대한민국", name: "해운대", englishName: "Haeundae", category: "자연", systemImage: "water.waves"),
        .init(id: "kr.hahoe", country: "대한민국", name: "하회마을", englishName: "Hahoe Folk Village", category: "문화", systemImage: "house.lodge.fill"),
        // 한 해 주간 보상이 최대 52번이라 52개로 맞췄다. 두 곳은 그림 파일이 아직 없어 심볼로 보인다.
        .init(id: "kr.namsan", country: "대한민국", name: "N서울타워", englishName: "N Seoul Tower", category: "건축", systemImage: "antenna.radiowaves.left.and.right"),
        .init(id: "kr.hallasan", country: "대한민국", name: "한라산", englishName: "Hallasan", category: "자연", systemImage: "tree.fill"),
        .init(id: "jp.fuji", country: "일본", name: "후지산", englishName: "Mount Fuji", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "jp.himeji", country: "일본", name: "히메지성", englishName: "Himeji Castle", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "jp.fushimi", country: "일본", name: "후시미 이나리", englishName: "Fushimi Inari", category: "문화", systemImage: "torii.gate.fill"),
        .init(id: "jp.itsukushima", country: "일본", name: "이쓰쿠시마 신사", englishName: "Itsukushima Shrine", category: "문화", systemImage: "water.waves"),
        .init(id: "jp.arashiyama", country: "일본", name: "아라시야마", englishName: "Arashiyama", category: "자연", systemImage: "leaf.fill"),
        .init(id: "us.liberty", country: "미국", name: "자유의 여신상", englishName: "Statue of Liberty", category: "건축", systemImage: "figure.stand"),
        .init(id: "us.grandcanyon", country: "미국", name: "그랜드 캐니언", englishName: "Grand Canyon", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "us.golden_gate", country: "미국", name: "금문교", englishName: "Golden Gate Bridge", category: "건축", systemImage: "bridge.fill"),
        .init(id: "us.yosemite", country: "미국", name: "요세미티", englishName: "Yosemite", category: "자연", systemImage: "waterfall.fill"),
        .init(id: "us.mount_rushmore", country: "미국", name: "러시모어산", englishName: "Mount Rushmore", category: "문화", systemImage: "mountain.2.fill"),
        .init(id: "gb.bigben", country: "영국", name: "빅벤", englishName: "Big Ben", category: "건축", systemImage: "clock.fill"),
        .init(id: "gb.stonehenge", country: "영국", name: "스톤헨지", englishName: "Stonehenge", category: "문화", systemImage: "circle.hexagongrid.fill"),
        .init(id: "gb.edinburgh", country: "영국", name: "에든버러성", englishName: "Edinburgh Castle", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "gb.lake_district", country: "영국", name: "레이크 디스트릭트", englishName: "Lake District", category: "자연", systemImage: "water.waves"),
        .init(id: "gb.tower_bridge", country: "영국", name: "타워 브리지", englishName: "Tower Bridge", category: "건축", systemImage: "bridge.fill"),
        .init(id: "fr.eiffel", country: "프랑스", name: "에펠탑", englishName: "Eiffel Tower", category: "건축", systemImage: "tower.fill"),
        .init(id: "fr.mont_saint_michel", country: "프랑스", name: "몽생미셸", englishName: "Mont-Saint-Michel", category: "문화", systemImage: "building.columns.fill"),
        .init(id: "fr.louvre", country: "프랑스", name: "루브르 박물관", englishName: "Louvre Museum", category: "문화", systemImage: "building.columns.fill"),
        .init(id: "fr.versailles", country: "프랑스", name: "베르사유 궁전", englishName: "Palace of Versailles", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "fr.alps", country: "프랑스", name: "프랑스 알프스", englishName: "French Alps", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "it.colosseum", country: "이탈리아", name: "콜로세움", englishName: "Colosseum", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "it.venice", country: "이탈리아", name: "베네치아", englishName: "Venice", category: "문화", systemImage: "water.waves"),
        .init(id: "it.pisa", country: "이탈리아", name: "피사의 사탑", englishName: "Leaning Tower of Pisa", category: "건축", systemImage: "building.fill"),
        .init(id: "it.dolomites", country: "이탈리아", name: "돌로미티", englishName: "Dolomites", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "it.amalfi", country: "이탈리아", name: "아말피 해안", englishName: "Amalfi Coast", category: "자연", systemImage: "water.waves"),
        .init(id: "cn.great_wall", country: "중국", name: "만리장성", englishName: "Great Wall", category: "건축", systemImage: "wall.3.fill"),
        .init(id: "cn.forbidden_city", country: "중국", name: "자금성", englishName: "Forbidden City", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "cn.zhangjiajie", country: "중국", name: "장자제", englishName: "Zhangjiajie", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "cn.terracotta", country: "중국", name: "병마용", englishName: "Terracotta Army", category: "문화", systemImage: "figure.stand"),
        .init(id: "cn.li_river", country: "중국", name: "리강", englishName: "Li River", category: "자연", systemImage: "water.waves"),
        .init(id: "es.sagrada", country: "스페인", name: "사그라다 파밀리아", englishName: "Sagrada Família", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "es.alhambra", country: "스페인", name: "알람브라", englishName: "Alhambra", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "es.park_guell", country: "스페인", name: "구엘 공원", englishName: "Park Güell", category: "문화", systemImage: "leaf.fill"),
        .init(id: "es.camino", country: "스페인", name: "산티아고 순례길", englishName: "Camino de Santiago", category: "문화", systemImage: "figure.walk"),
        .init(id: "es.teide", country: "스페인", name: "테이데산", englishName: "Mount Teide", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "th.grand_palace", country: "태국", name: "왕궁", englishName: "Grand Palace", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "th.phiphi", country: "태국", name: "피피섬", englishName: "Phi Phi Islands", category: "자연", systemImage: "water.waves"),
        .init(id: "th.ayutthaya", country: "태국", name: "아유타야", englishName: "Ayutthaya", category: "문화", systemImage: "building.columns.fill"),
        .init(id: "th.doi_inthanon", country: "태국", name: "도이인타논", englishName: "Doi Inthanon", category: "자연", systemImage: "mountain.2.fill"),
        .init(id: "th.wat_arun", country: "태국", name: "왓 아룬", englishName: "Wat Arun", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "au.opera", country: "호주", name: "시드니 오페라 하우스", englishName: "Sydney Opera House", category: "건축", systemImage: "building.columns.fill"),
        .init(id: "au.great_barrier", country: "호주", name: "그레이트 배리어 리프", englishName: "Great Barrier Reef", category: "자연", systemImage: "water.waves"),
        .init(id: "au.uluru", country: "호주", name: "울루루", englishName: "Uluru", category: "문화", systemImage: "mountain.2.fill"),
        .init(id: "au.twelve_apostles", country: "호주", name: "12사도 바위", englishName: "Twelve Apostles", category: "자연", systemImage: "water.waves"),
        .init(id: "au.harbour_bridge", country: "호주", name: "시드니 하버 브리지", englishName: "Sydney Harbour Bridge", category: "건축", systemImage: "bridge.fill"),
    ]

    /// 이번 시즌에 이미 고른 랜드마크는 후보에서 뺀다. 50개를 다 모으면(한 해 보상은 최대 52번) 전체에서 다시 돌린다.
    static func weeklyChoices(for season: MapHomeGrowthSeason) -> [MapHomeLandmarkCandidate] {
        guard !candidates.isEmpty else { return [] }
        let chosen = Set(season.chosenEvolutions)
        let remaining = candidates.filter { !chosen.contains($0.id) }
        let pool = remaining.isEmpty ? candidates : remaining
        let start = (season.year &+ season.chosenEvolutions.count * 3) % pool.count
        return (0..<min(3, pool.count)).map {
            pool[(start + $0) % pool.count]
        }
    }
}

enum MapHomeGrowthAccessoryCatalog {
    private static let symbols = [
        "crown.fill", "sparkles", "leaf.fill", "sun.max.fill", "flower.fill",
    ]

    /// 장식이 따온 랜드마크. 장식 id는 `cat.accessory.<랜드마크 id>`다.
    static func landmark(for accessoryID: String?) -> MapHomeLandmarkCandidate? {
        guard let accessoryID, !accessoryID.isEmpty else { return nil }
        return MapHomeLandmarkCatalog.candidates.first { $0.accessoryID == accessoryID }
    }

    /// 화랑이 아이콘에 달리는 무늬. 랜드마크 장식은 그 랜드마크의 심볼(건축·자연·문화)을 쓰고,
    /// 옛 장식 id처럼 랜드마크를 못 찾으면 예전처럼 id로 고른 기본 심볼을 쓴다.
    static func symbol(for accessoryID: String?) -> String? {
        guard let accessoryID, !accessoryID.isEmpty else { return nil }
        if let landmark = landmark(for: accessoryID) { return landmark.systemImage }
        let index = accessoryID.utf8.reduce(0) { ($0 + Int($1)) % symbols.count }
        return symbols[index]
    }
}

/// The growth history is read many times per body pass (every marker and the
/// playback marker), so decode the stored JSON once per stored value.
@MainActor
final class MapHomeGrowthHistoryCache {
    private var data = Data()
    private var decoded: MapHomeGrowthHistory?

    func history(for data: Data) -> MapHomeGrowthHistory? {
        if let decoded, self.data == data { return decoded }
        guard let value = try? JSONDecoder().decode(MapHomeGrowthHistory.self, from: data) else {
            return nil
        }
        self.data = data
        decoded = value
        return value
    }
}

/// Header date text is rebuilt on every invalidation; DateFormatter creation
/// is expensive, so reuse one per format and locale.
@MainActor
enum MapHomeDateText {
    private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, locale: Locale) -> String {
        let key = "\(locale.identifier)|\(format)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
}

struct MapHomeGrowthHistory: Codable, Equatable {
    var season: MapHomeGrowthSeason
    var archives: [MapHomeGrowthSeason] = []

    init(season: MapHomeGrowthSeason, archives: [MapHomeGrowthSeason] = []) {
        self.season = season
        self.archives = archives
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = try c.decode(MapHomeGrowthSeason.self, forKey: .season)
        archives = try c.decodeIfPresent([MapHomeGrowthSeason].self, forKey: .archives) ?? []
    }

    static func initial(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Self {
        Self(season: MapHomeGrowthSeason(year: calendar.component(.year, from: date)))
    }
}

enum MapHomeGrowthPolicy {
    static let storageKey = "taption.mapHome.growth.v1"

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    /// 주간 보상은 연속 달성 7일마다 한 번. 7일 단위로 남은 일수(1~7)를 돌려준다.
    static func daysUntilNextWeeklyReward(streak: Int) -> Int {
        7 - max(0, streak) % 7
    }

    static func qualifies(actualCount: Int, unconfirmedCount: Int) -> Bool {
        actualCount > 0 && unconfirmedCount == 0
    }

    static func qualifiesDay(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        on date: Date,
        asOf now: Date,
        calendar: Calendar
    ) -> Bool {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let actualCount = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && start < span.end
                && RecordAnalysisCategoryPolicy.categoryID(for: $0) != "unconfirmed"
        }.count
        let unconfirmedCount = MapHomeTimeRailSegmentEngine.segments(
            from: actuals,
            travel: travel,
            on: date,
            asOf: now,
            calendar: calendar
        ).filter { $0.categoryID == "unconfirmed" }.count
        return qualifies(actualCount: actualCount, unconfirmedCount: unconfirmedCount)
    }

    static func maximumLevel(year: Int, timeZone: TimeZone = .autoupdatingCurrent) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = 7
        components.day = 1
        guard let date = calendar.date(from: components),
              let days = calendar.range(of: .day, in: .year, for: date)?.count else {
            return 365
        }
        return days
    }

    static func artworkName(level: Int) -> String {
        let paddedLevel = String(
            format: "%03d",
            locale: Locale(identifier: "en_US_POSIX"),
            min(max(level, 1), 366)
        )
        return "HomeEvolution\(paddedLevel)"
    }

    static func isLeapDay(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.month, .day], from: date)
        return components.month == 2 && components.day == 29
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    static func date(for key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
    }

    static func closePendingDay(
        in history: inout MapHomeGrowthHistory,
        asOf now: Date,
        calendar: Calendar
    ) {
        let today = calendar.startOfDay(for: now)
        guard let key = history.season.pendingDay,
              let pendingDate = date(for: key, calendar: calendar),
              calendar.startOfDay(for: pendingDate) < today else { return }
        closeDay(
            key: key,
            date: pendingDate,
            qualified: history.season.pendingDayQualified,
            in: &history,
            calendar: calendar
        )
        history.season.pendingDay = nil
        history.season.pendingDayQualified = false
    }

    static func observeCurrentDay(
        in history: inout MapHomeGrowthHistory,
        date: Date,
        qualified: Bool,
        calendar: Calendar
    ) {
        let year = calendar.component(.year, from: date)
        advanceSeason(in: &history, to: year)
        let key = dayKey(date, calendar: calendar)
        history.season.pendingDay = key
        history.season.pendingDayQualified = qualified
    }

    @discardableResult
    static func awardRecentCompletion(
        in history: inout MapHomeGrowthHistory,
        day: Date,
        asOf now: Date,
        qualified: Bool,
        calendar: Calendar
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        guard qualified,
              let distance = calendar.dateComponents([.day], from: dayStart, to: today).day,
              (1...7).contains(distance) else { return false }
        let key = dayKey(day, calendar: calendar)
        let year = calendar.component(.year, from: day)
        if history.season.year == year {
            return awardRecentCompletion(key: key, in: &history.season, calendar: calendar)
        }
        guard let index = history.archives.firstIndex(where: { $0.year == year }) else {
            return false
        }
        return awardRecentCompletion(key: key, in: &history.archives[index], calendar: calendar)
    }

    static func settleAndAwardRecentCompletion(
        in history: inout MapHomeGrowthHistory,
        day: Date,
        asOf now: Date,
        qualified: Bool,
        calendar: Calendar
    ) {
        closePendingDay(in: &history, asOf: now, calendar: calendar)
        awardRecentCompletion(
            in: &history,
            day: day,
            asOf: now,
            qualified: qualified,
            calendar: calendar
        )
    }

    private static func awardRecentCompletion(
        key: String,
        in season: inout MapHomeGrowthSeason,
        calendar: Calendar
    ) -> Bool {
        var rewardedDays = season.recentCompletionRewardedDays ?? []
        guard !rewardedDays.contains(key) else { return false }
        rewardedDays.append(key)
        season.recentCompletionRewardedDays = rewardedDays
        season.level = min(
            maximumLevel(year: season.year, timeZone: calendar.timeZone),
            season.level + 1
        )
        return true
    }

    @discardableResult
    static func redeemWeeklyReward(
        evolutionID: String,
        landPlotID: String,
        accessoryID: String,
        in history: inout MapHomeGrowthHistory
    ) -> Bool {
        guard history.season.pendingWeeklyRewards > 0,
              !evolutionID.isEmpty,
              !landPlotID.isEmpty,
              !accessoryID.isEmpty else { return false }
        history.season.pendingWeeklyRewards -= 1
        history.season.chosenEvolutions.append(evolutionID)
        history.season.landPlots.append(landPlotID)
        if !history.season.accessories.contains(accessoryID) {
            history.season.accessories.append(accessoryID)
        }
        return true
    }

    @discardableResult
    static func equipAccessory(
        _ accessoryID: String,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.accessories.contains(accessoryID) else { return false }
        season.equippedAccessory = accessoryID
        return true
    }

    /// 땅 조각을 붙일 수 있는 빈 칸: 이미 놓인 땅과 변을 맞댄 칸. 아직 아무것도 없으면 (0,0)(집 자리).
    static func placementCandidates(in season: MapHomeGrowthSeason) -> [(x: Int, y: Int)] {
        let placements = season.landPlotPlacements ?? []
        guard !placements.isEmpty else { return [(0, 0)] }
        let occupied = Set(placements.map { "\($0.x),\($0.y)" })
        var seen = Set<String>()
        var result: [(x: Int, y: Int)] = []
        for placement in placements {
            for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                let x = placement.x + dx, y = placement.y + dy
                let key = "\(x),\(y)"
                if !occupied.contains(key), seen.insert(key).inserted { result.append((x, y)) }
            }
        }
        return result
    }

    /// 사용자가 고른 칸에 땅 조각을 붙인다. 붙일 수 있는 빈 칸이 아니면 false.
    @discardableResult
    static func placeLandPlot(
        _ plotID: String,
        atX x: Int,
        y: Int,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.landPlots.contains(plotID),
              !(season.landPlotPlacements ?? []).contains(where: { $0.plotID == plotID }),
              placementCandidates(in: season).contains(where: { $0.x == x && $0.y == y }) else { return false }
        var placements = season.landPlotPlacements ?? []
        placements.append(.init(plotID: plotID, x: x, y: y))
        season.landPlotPlacements = placements
        return true
    }

    @discardableResult
    static func placeLandPlot(
        _ plotID: String,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.landPlots.contains(plotID) else { return false }
        var placements = season.landPlotPlacements ?? []
        guard !placements.contains(where: { $0.plotID == plotID }) else {
            return false
        }
        if placements.isEmpty {
            placements.append(.init(plotID: plotID, x: 0, y: 0))
            season.landPlotPlacements = placements
            return true
        }
        let occupied = Set(placements.map { "\($0.x),\($0.y)" })
        let directions = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        for anchor in placements.reversed() {
            for (dx, dy) in directions {
                let x = anchor.x + dx
                let y = anchor.y + dy
                guard !occupied.contains("\(x),\(y)") else { continue }
                placements.append(.init(plotID: plotID, x: x, y: y))
                season.landPlotPlacements = placements
                return true
            }
        }
        return false
    }

    private static func closeDay(
        key: String,
        date: Date,
        qualified: Bool,
        in history: inout MapHomeGrowthHistory,
        calendar: Calendar
    ) {
        advanceSeason(in: &history, to: calendar.component(.year, from: date))
        guard history.season.lastClosedDay != key else { return }
        let previousDay = calendar.date(byAdding: .day, value: -1, to: date)
            .map { dayKey($0, calendar: calendar) }
        if history.season.lastClosedDay != previousDay {
            history.season.streak = 0
        }
        if qualified {
            history.season.level = min(
                maximumLevel(year: history.season.year, timeZone: calendar.timeZone),
                history.season.level + 1
            )
            history.season.streak += 1
            if history.season.streak.isMultiple(of: 7) {
                history.season.pendingWeeklyRewards += 1
            }
            var rewardedDays = history.season.recentCompletionRewardedDays ?? []
            if !rewardedDays.contains(key) {
                rewardedDays.append(key)
                history.season.recentCompletionRewardedDays = rewardedDays
            }
        } else {
            history.season.streak = 0
        }
        history.season.lastClosedDay = key
    }

    private static func advanceSeason(in history: inout MapHomeGrowthHistory, to year: Int) {
        guard year > history.season.year else { return }
        history.archives.append(history.season)
        history.season = MapHomeGrowthSeason(year: year)
    }
}

@MainActor
struct MapHomeView: View {
    private static let dayViewSignpostLog = OSLog(
        subsystem: "com.taption.plan",
        category: .pointsOfInterest
    )
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var model: AppModel
    @Bindable private var proAccess: TaptionProAccessController
    private let onInitialDataReady: () -> Void

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapCameraRevision = 0
    @State private var appleViewportCommand: MapHomeAppleViewportCommand?
    @State private var vectorMapViewportStore = MapHomeVectorViewportStore()
    @State private var isMenuOpen = false
    @State private var isDateWeekExpanded = false
    @State private var isCalendarPresented = false
    @State private var selectedLocationDestination: MapHomeLocationDestination?
    @State private var isTransitLocationsPresented = false
    @State private var isLocationMenuExpanded = false
    @State private var isUserLocationsMenuExpanded = false
    @State private var isCategoryMenuExpanded = false
    @State private var isCategoryAddPresented = false
    @State private var isDisplayMenuExpanded = false
    @State private var isStrideCalibrationPresented = false
    @State private var isMemoAddMenuPresented = false
    @State private var isPlacingMapMemo = false
    @State private var dismissedMemoPreviewIDs = Set<UUID>()
    private let isStickerMode = true
    @State private var selectedMapStickerEditor: MapHomeStickerEditorTarget?
    @State private var isAppleWatchMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    @State private var isGPSLoggingMenuExpanded = false
    @State private var isDataProtectionPresented = false
    @State private var isSettingsResetConfirmationPresented = false
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue
    @AppStorage(MapHomePlaybackZoomMode.storageKey)
    private var playbackZoomModeRaw = MapHomePlaybackZoomMode.adaptive.rawValue
    @AppStorage("mapHomeLeftControlsExpanded")
    private var isLeftControlsExpanded = false
    @AppStorage(MapHomeLayoutStyle.storageKey)
    private var layoutStyleRaw = MapHomeLayoutStyle.classic.rawValue
    @AppStorage(MapHomeRecordingLayers.storageKey)
    private var recordingLayersRaw = ""
    @State private var isScreenRecording = false
    @State private var photoMoments: [PhotoMoment] = []
    @State private var photosNeedReadingRetry = false
    @AppStorage("mapHomeShowsPhotos") private var showsPhotosOnMap = true
    @AppStorage("mapHomeMemoDisplay") private var memoDisplayRaw = MapHomeMemoDisplayMode.all.rawValue
    @State private var pendingMemoLocationID: UUID?
    @State private var isMapAttributionPresented = false
    /// 땅은 벡터 지도에서만 그려져서, 붙일 타일이 있고 집 근처로 확대하면 벡터 스타일로 자동 전환했다가 끝나면 되돌린다.
    @AppStorage("mapHomeAutoLandStyle") private var autoLandStyleEnabled = true
    /// "원래 스타일|자동 전환한 스타일". 비어 있으면 자동 전환 중이 아니다.
    @AppStorage("mapHomeAutoLandStyleState") private var autoLandStyleState = ""
    @State private var photoClusterCache = MapHomePhotoClusterCache()
    @State private var photoAlbumSelection: MapHomePhotoAlbumSelection?
    private let photoLibrary = ApplePhotoLibraryService()
    @State private var isRecordingOptionsPresented = false
    @State private var isRecordedVideoSharePresented = false
    @State private var recordingFailureMessage: String?
    @State private var recordedVideoURL: URL?
    @State private var screenRecorder = MapHomeScreenRecorder()
    @AppStorage(MapHomeGrowthPolicy.storageKey)
    private var homeGrowthData = Data()
    @State private var growthHistoryCache = MapHomeGrowthHistoryCache()
    @State private var compassControlState: MapHomeCompassControlState = .directionArrow
    @State private var headingMonitor = MapHomeHeadingMonitor()
    @State private var selectedScope: TimeScale = .day
    @State private var selectedTimelineMinute: Int?
    @State private var selectedPawprintTimestamp: Date?
    @State private var selectedPawprintCoordinate: CLLocationCoordinate2D?
    @State private var isTimelineSelectionPinned = false
    @State private var sectionEditSelection: MapHomeSectionEditSelection?
    @State private var isUnconfirmedReviewPresented = false
    @State private var focusedUnconfirmedReviewSegment: MapHomeTimeRailSegment?
    @State private var pendingUnconfirmedEditMinute: Int?
    @State private var isMapCenteredOnUser = false
    @SceneStorage("MapHome.userTrackingMode")
    private var userTrackingModeRawValue = MapHomeUserTrackingMode.idle.rawValue
    @State private var currentLocationRequestTask: Task<Void, Never>?
    @State private var initialLocationRequestTask: Task<Void, Never>?
    @State private var routeReadingsPreparationTask: Task<Void, Never>?
    @State private var routeReadingsPreparationGeneration =
        MapHomeRouteReadingsPreparationGeneration()
    @State private var hasAppliedInitialLocation = false
    @State private var hasAppliedInitialMapFocus = false
    @State private var startupCameraPolicy = MapHomeStartupCameraPolicy()
    @State private var hasCancelledInitialLocationFocus = false
    @State private var mapSearchText = ""
    @State private var mapSearchResults: [MapHomeSearchResult] = []
    @State private var selectedSearchPin: MapHomeSearchResult?
    @State private var isSearchPinMenuPresented = false
    @State private var selectedMarkerInfo: MapHomeMarkerInfoKind?
    @State private var fogOfWarEnabled = true
    @State private var isLongPressMenuPresented = false
    @State private var isDaySummaryPresented = false
    @State private var pendingLongPressCoordinate: CLLocationCoordinate2D?
    @State private var requestingPermission: RequiredPermission?
    @State private var selectedUserLocation: MapHomeUserLocationSelection?
    @State private var selectedTransitBoardingCandidate: TransitBoardingCandidate?
    @State private var selectedPredictedRoute: MapPredictedRoute?
    @State private var pendingUserLocationSelection: MapHomeUserLocationSelection?
    @State private var mapSearchTask: Task<Void, Never>?
    @State private var transitPOIRefreshTask: Task<Void, Never>?
    @State private var transitPOIRefreshGeneration: UInt64 = 0
    @State private var nearbyTransitPlaces: [TransitBoardingPlace] = []
    @State private var transitBoardingReadingsRevision: UInt64 = 0
    @State private var lastTransitBoardingLiveRefreshAt: Date?
    @State private var nearbyTransitPlacesRevision: UInt64 = 0
    @State private var mapSearchCompleter = MapHomeSearchCompleter()
    @State private var mapSearchRequestID = UUID()
    @FocusState private var isMapSearchFocused: Bool
    @State private var isSearchExpanded = false
    @State private var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var timeRailSegments: [MapHomeTimeRailSegment] = []
    @State private var routeProjection: RouteTimelineProjection?
    @State private var routeActualIndex: RouteTimelineDataEngine.ActualIndex?
    @State private var wbsPlaybackProjection: MapHomeWBSPlaybackProjection?
    @State private var dayDataSnapshot: PlanDayDataSnapshot?
    @State private var dayDataIsPreview = false
    @State private var hasDeferredWBSPlaybackRefresh = false
    @State private var routeReadings: [SensorReading] = []
    @State private var routeReadingsLoadState: MapHomeRouteReadingsLoadState = .idle
    @State private var hasReportedInitialDataReady = false
    @State private var normalizedRouteReadings: [SensorReading] = []
    @State private var currentMapLocationReading: SensorReading?
    @State private var historicalPlaybackReadings: [SensorReading] = []
    @State private var displayRouteReadings: [SensorReading] = []
    @State private var lastPreparedRouteReadingsSignature: String?
    @State private var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] = []
    @State private var cachedTemporaryLocations: [SubwayStationCatalog.TemporaryLocation] = []
    @State private var expectedRouteOverlays: [MapHomeExpectedRouteOverlay] = []
    @State private var wbsGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] = []
    @State private var pendingForecastRouteState: MapHomeForecastRouteState?
    @State private var expectedRouteCache: [ExpectedRouteRequest: [CLLocationCoordinate2D]] = [:]
    @State private var expectedRouteRefreshTask: Task<Void, Never>?
    @State private var expectedRouteRefreshGeneration: UInt64 = 0
    @State private var wbsExpectedRouteRequests: [ExpectedRouteRequest] = []
    @State private var wbsExpectedRouteRequestsInputKey: MapHomeExpectedRouteInputKey?
    @State private var liveRouteProjectionRefreshTask: Task<Void, Never>?
    @State private var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )
    @State private var sharedZoomLevel: CGFloat = 1
    @State private var zoomResetToken = 0
    @State private var weatherVisibleStartMinute = 0
    @State private var weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var timeSidebarVisibleStartMinute = 0
    @State private var timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var cachedWeatherContexts: [WeatherContext]
    @State private var activePaletteCategoryID: String?
    @State private var customPaletteColor = Color.tpReferenceMint
    @State private var mapCameraFrameProjection = MapHomeCameraFrameProjection()
    @State private var mapRenderCache = MapHomeMapRenderCache()
    @State private var liveZoomGovernor = MapHomeLiveZoomGovernor()
    @State private var playbackZoomSmoother = MapHomePlaybackZoomSmoother()
    @State private var playbackZoomPlan = MapHomePlaybackZoomPlan(inputs: [])
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
    @State private var isPlaybackIntroActive = false
    @State private var playbackIntroTask: Task<Void, Never>?
    @State private var lastPlaybackFocusLogUptime: TimeInterval = 0
    @State private var lastPlaybackMarkerUptime: TimeInterval = 0
    @State private var lastTimelineMapFocusUptime: TimeInterval = 0
    @State private var dayPlaybackTask: Task<Void, Never>?
    @State private var mapDayCacheWriteSignature: Int?

    private static let categoryPaletteHexes = [
        "#8FD9C5", "#A9CFF0", "#A7DDEB", "#C2B4E9",
        "#B8B7E8", "#F2B18D", "#F2A8B8", "#CBD5E1",
        "#F2D58D", "#F28FA9", "#B7DCC7", "#B7D5EE",
    ]

    private static let mapCacheAlgorithmKey = "route-document-v10"

    private enum Layout {
        static let horizontalInset: CGFloat = 10
        static let dateBadgeSize: CGFloat = 56
        static let headerVisibleHeight: CGFloat = 46
        static let headerHitTarget: CGFloat = 44
        static let headerIcon: CGFloat = 19
        static let mapControlSize = MapHomeOverlayLayoutMath.controlSize
        static let mapControlIcon: CGFloat = 15
        static let mapControlSpacing = MapHomeOverlayLayoutMath.controlSpacing
        static let timeRailWidth: CGFloat = 44
        static let weatherRailWidth: CGFloat = 62
        static let timeRailTopMargin: CGFloat = 46
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
        _timeRailSegments = State(initialValue: [])
        let storedWeather: [WeatherContext] = model.snapshot.weather
        var completeWeather: [WeatherContext] = []
        for context in storedWeather where MapHomeWeatherDisplayPolicy.isComplete(context) {
            completeWeather.append(context)
        }
        let displayWeather: [WeatherContext] = MapHomeWeatherTimelineMath.coalescedDisplayContexts(completeWeather)
        _cachedWeatherContexts = State(initialValue: displayWeather)
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

    /// 검색 오버레이가 실제로 열려 있어 지도 탭으로 닫아야 하는 상태.
    /// 이게 아닐 때는 지도에 탭 제스처를 붙이지 않아 지도 팬·핀치와 경합하지 않는다.
    private var isSearchDismissable: Bool {
        isSearchExpanded
            || isMapSearchFocused
            || hasMapSearchResults
            || !mapSearchText.isEmpty
            || selectedSearchPin != nil
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
        CGPoint(x: mapViewportSize.width / 2, y: mapViewportSize.height / 2)
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
                if selection.segment.categoryID == "unconfirmed" {
                    rewardRecentCompletedDay(selection.date)
                }
            }
        )
    }

    private func quickConfirmUnconfirmed(
        _ segment: MapHomeTimeRailSegment,
        as category: MapHomeSidebarMajorCategory
    ) async -> Bool {
        guard model.isBootstrapped else { return false }
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = model.selectedDate
        let startOfDay = calendar.startOfDay(for: selectedDay)
        guard segment.categoryID == "unconfirmed",
              segment.startMinute < segment.endMinute,
              let start = calendar.date(byAdding: .minute, value: segment.startMinute, to: startOfDay),
              let end = calendar.date(byAdding: .minute, value: segment.endMinute, to: startOfDay)
        else { return false }
        let original = ActivityCorrectionOption(
            id: "phase.unconfirmed",
            title: segment.title,
            behavior: segment.behavior,
            categoryID: "unconfirmed",
            systemImage: "questionmark",
            isAutomatic: false,
            isCustom: false
        )
        let choice = ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.title,
            behavior: nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
        let span = TimeSpan(start: start, end: end)
        let request = ActivitySectionEditRequest(
            sourceIDs: segment.sourceIDs,
            originalSpan: span,
            originalOption: original,
            mode: .replace(editedSpan: span, option: choice)
        )
        guard await model.saveActivitySectionEdit(request) != nil else { return false }
        refreshTimeRailSegments()
        if calendar.isDate(model.selectedDate, inSameDayAs: selectedDay) {
            selectedTimelineMinute = MapHomeUnconfirmedReviewPolicy.midpointMinute(for: segment)
            isTimelineSelectionPinned = true
        }
        rewardRecentCompletedDay(selectedDay)
        return true
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

    private var foregroundContent: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()
                .zIndex(MapHomeLayerPriority.map)

            mapSideRails

            if isPlacingMapMemo {
                mapMemoPlacementOverlay
                    .zIndex(MapHomeLayerPriority.loading)
            } else if recordingShows(\.sidebarMemos), memoDisplayMode == .all {
                memoOverlayStack
                    .zIndex(MapHomeLayerPriority.loading)
            }

            if isDayDataLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("날짜 데이터 불러오는 중", "Loading day data"))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.tpSurface.opacity(0.92), in: Capsule())
                .padding(.top, topOverlayHeight + 8)
                .allowsHitTesting(false)
                .zIndex(MapHomeLayerPriority.loading)
            }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Layout.headerVisibleHeight + 8)
                    .allowsHitTesting(false)
                if !isScreenRecording,
                   isSearchExpanded || isMapSearchFocused || hasMapSearchResults || !mapSearchText.isEmpty || selectedSearchPin != nil {
                    HStack(alignment: .top, spacing: 0) {
                        mapSearchBar
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .zIndex(MapHomeLayerPriority.search)

            if isMenuOpen, !isScreenRecording {
                menu
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(MapHomeLayerPriority.menu)
            }

            if !isScreenRecording {
                dateBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, Layout.horizontalInset)
                    .padding(.trailing, Layout.horizontalInset)
                    .zIndex(MapHomeLayerPriority.header)
            }

            if !isScreenRecording {
                VStack(alignment: .leading, spacing: 0) {
                    if !layoutStyle.movesActionsToBottom {
                        Button {
                            openMenu()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                                .frame(width: 40, height: 34)
                                .background(Color.tpSurface.opacity(0.96), in: Capsule())
                                .overlay { Capsule().stroke(Color.tpLine.opacity(0.78), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .accessibilityLabel(language.text("메뉴 열기", "Open menu"))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Layout.horizontalInset)
                .padding(.top, 2)
                .zIndex(MapHomeLayerPriority.header)
            }

            if !isScreenRecording, !isMenuOpen, layoutStyle.movesActionsToBottom {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bottomActionBar
                }
                .zIndex(MapHomeLayerPriority.header)
            }
        }
        .onChange(of: isDayPlaybackRunning) { _, isRunning in
            if !isRunning { finishRecordingPlayback() }
        }
        .task(id: model.selectedDate) { await loadPhotoMoments() }
        .onChange(of: showsPhotosOnMap) { _, _ in Task { await loadPhotoMoments() } }
        // 하루 데이터가 늦게 들어오면 위치 없는 사진의 추정 위치도 다시 맞춘다.
        .onChange(of: isDayDataLoading) { _, loading in
            if !loading, photosNeedReadingRetry { Task { await loadPhotoMoments() } }
        }
        .sheet(item: $photoAlbumSelection) { selection in
            MapHomePhotoAlbumSheet(moments: selection.moments, language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRecordingOptionsPresented) {
            MapHomeRecordingOptionsSheet(
                layers: Binding(
                    get: { recordingLayers },
                    set: { recordingLayersRaw = $0.rawValue }
                ),
                language: language,
                onStart: startRecordingPlayback
            )
            .presentationDetents([.height(560), .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            language.text("화면 녹화", "Screen recording"),
            isPresented: Binding(
                get: { recordingFailureMessage != nil },
                set: { if !$0 { recordingFailureMessage = nil } }
            )
        ) {
            Button(language.text("확인", "OK"), role: .cancel) { recordingFailureMessage = nil }
        } message: {
            Text(recordingFailureMessage ?? "")
        }
        .sheet(isPresented: $isRecordedVideoSharePresented) {
            if let recordedVideoURL {
                MapHomeShareSheet(url: recordedVideoURL)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    var body: some View {
        lifecycleModifiers(presentationModifiers(baseContent))
    }

    /// `body`의 수정자 체인이 길면 타입 검사가 느려져(CI에서 시간 초과) 세 덩어리로 나눈다.
    private var baseContent: some View {
        Group {
            if scenePhase == .background {
                Color.tpSurface.ignoresSafeArea()
            } else {
                foregroundContent
            }
        }
        .coordinateSpace(name: "mapHomeViewport")
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { size in
                let integralSize = CGSize(
                    width: size.width.rounded(),
                    height: size.height.rounded()
                )
                Task { @MainActor in
                    await Task.yield()
                    guard mapViewportSize != integralSize else { return }
                    mapViewportSize = integralSize
                }
            }
        )
        .preferredColorScheme(.light)
    }

    private func presentationModifiers(_ content: some View) -> some View {
        content
        .sheet(item: $selectedMarkerInfo) { info in
            MapHomeMarkerInfoSheet(kind: info, language: language)
                .presentationDetents([.height(320), .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isDaySummaryPresented) {
            MapHomeDaySummarySheet(
                date: model.selectedDate,
                categories: daySummaryCategories,
                stepCount: dayStepCount,
                travelDistances: MapHomeDayTravelSummary.entries(
                    from: currentDayDataSnapshot?.travel ?? []
                ),
                growthData: $homeGrowthData,
                language: language,
                growthCard: MapHomeGrowthCardInfo(
                    level: homeGrowthHistory.season.level,
                    status: homeGrowthMarkerStatus,
                    isQualifiedToday: isHomeGrowthQualifiedToday,
                    streak: homeGrowthHistory.season.streak,
                    pendingWeeklyRewards: homeGrowthHistory.season.pendingWeeklyRewards
                )
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isStrideCalibrationPresented) {
            MapHomeStrideCalibrationSheet(language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCalendarPresented) {
            MapHomeCalendarSheet(
                selectedDate: $model.selectedDate,
                holidayName: { date in
                    TimelineAxisGrid.koreanHolidayName(on: date)
                },
                logStatuses: { month in
                    let actuals = model.snapshot.actuals
                    let travel = model.snapshot.travel
                    return await Task.detached(priority: .userInitiated) {
                        MapHomeCalendarLogStatusPolicy.statuses(
                            actuals: actuals,
                            travel: travel,
                            month: month,
                            asOf: .now,
                            calendar: MapHomeGrowthPolicy.localCalendar
                        )
                    }.value
                },
                timeTotals: { month in await calendarTimeTotals(month: month, includePhotos: true) },
                liveTotals: { month in await calendarTimeTotals(month: month, includePhotos: false) },
                timeTint: { categoryID in
                    MapHomeSidebarMajorCategory.presentation(
                        for: categoryID,
                        categoryColors: model.settings.mapCategoryColors
                    ).tint
                },
                language: language,
                liveToken: ((model.latestSensorReading?.timestamp.timeIntervalSince1970 ?? 0) / 3).rounded(.down)
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
                language: language,
                onRequestLocation: { id in beginMemoLocationPick(id) }
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
        .sheet(item: $selectedPredictedRoute) { route in
            MapHomePredictedRouteMenu(model: model, route: route, language: language)
                .presentationDetents([.height(230)])
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
        .sheet(isPresented: $isMapAttributionPresented) {
            MapHomeAttributionSheet(language: language)
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
        }
        // 지도 메모·일정 메모를 나누지 않고 "메모" 하나로 연다. 위치·시간은 편집 화면에서 더한다.
        .onChange(of: isMemoAddMenuPresented) { _, presented in
            guard presented else { return }
            isMemoAddMenuPresented = false
            addMemo()
        }
        .confirmationDialog(
            language.text("지도에 추가", "Add to map"),
            isPresented: $isLongPressMenuPresented,
            titleVisibility: .visible
        ) {
            Button {
                routeLongPress(.location)
            } label: {
                Label(
                    language.text("위치 추가", "Add location"),
                    systemImage: "mappin.and.ellipse"
                )
            }
            Button {
                routeLongPress(.memo)
            } label: {
                Label(
                    language.text("지도 메모 추가", "Add map memo"),
                    systemImage: "note.text.badge.plus"
                )
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {
                pendingLongPressCoordinate = nil
            }
        } message: {
            Text(
                language.text(
                    "길게 누른 위치에 추가할 항목을 선택하세요.",
                    "Choose what to add at the long-pressed location."
                )
            )
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
        .sheet(
            isPresented: $isUnconfirmedReviewPresented,
            onDismiss: {
                focusedUnconfirmedReviewSegment = nil
                guard let minute = pendingUnconfirmedEditMinute else { return }
                pendingUnconfirmedEditMinute = nil
                Task { @MainActor in
                    await Task.yield()
                    openSectionEditor(at: minute)
                }
            }
        ) {
            MapHomeUnconfirmedReviewSheet(
                date: model.selectedDate,
                segments: timeRailSegments,
                focusedSegment: focusedUnconfirmedReviewSegment,
                recentDates: focusedUnconfirmedReviewSegment == nil
                    ? MapHomeUnconfirmedReviewPolicy.recentDates()
                    : [],
                language: language,
                onDateSelect: { day in
                    guard !Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) else { return }
                    model.selectedDate = day
                    refreshTimeRailSegments()
                },
                onSelect: { segment in
                    pendingUnconfirmedEditMinute = MapHomeUnconfirmedReviewPolicy
                        .midpointMinute(for: segment)
                    isUnconfirmedReviewPresented = false
                },
                onQuickConfirm: { segment, category in
                    await quickConfirmUnconfirmed(segment, as: category)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            language.text("설정을 기본값으로 초기화할까요?", "Reset settings to defaults?"),
            isPresented: $isSettingsResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("설정 초기화", "Reset settings"), role: .destructive) {
                isMenuOpen = false
                Task { await model.resetSettingsToDefaults() }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("계획과 기록은 삭제되지 않습니다.", "Your plans and records will not be deleted."))
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
        .onChange(of: isMenuOpen) { _, isOpen in
            guard isOpen else { return }
            Task { @MainActor in await model.refreshPermissions() }
        }
    }

    private func lifecycleModifiers(_ content: some View) -> some View {
        content
        .onAppear {
            if scenePhase == .active { restoreInitialMapZoom() }
            prepareRouteProjectionReadings()
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.snapshotRevision) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.dayProjectionRevision) { _, _ in
            routeActualIndex = nil
        }
        .onChange(of: model.isBootstrapped) { _, isReady in
            if isReady { refreshHomeGrowth(at: .now) }
        }
        .onChange(of: model.selectedDate) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onDisappear {
            routeReadingsPreparationTask?.cancel()
            routeReadingsPreparationTask = nil
            routeReadingsPreparationGeneration.advance()
            lastPreparedRouteReadingsSignature = nil
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            initialLocationRequestTask?.cancel()
            initialLocationRequestTask = nil
            mapSearchTask?.cancel()
            mapSearchTask = nil
            expectedRouteRefreshTask?.cancel()
            expectedRouteRefreshTask = nil
            expectedRouteRefreshGeneration &+= 1
            liveRouteProjectionRefreshTask?.cancel()
            liveRouteProjectionRefreshTask = nil
            transitPOIRefreshTask?.cancel()
            transitPOIRefreshTask = nil
            mapSearchCompleter.clear()
            stopDayPlayback(resetProgress: true)
            headingMonitor.stop()
        }
        .task(id: daySourceTaskKey) { await runDaySourceTask() }
        .task(id: routeReadingsTaskKey) { await runRouteReadingsTask() }
        .onChange(
            of: MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                model.latestSensorReading
            )
        ) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.latestSensorReading?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: currentMapLocationReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard selectedTimelineMinute == nil,
                  Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
                  userTrackingMode.keepsCameraLocked
            else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
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
        .onChange(of: isNearHomeLand) { _, near in applyAutoLandStyle(near: near) }
        .onChange(of: autoLandStyleEnabled) { _, enabled in
            if !enabled { applyAutoLandStyle(near: false) }
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
                resetDayScopedMapState(for: newDate)
                hasUserAdjustedMap = false
                routeReadingsLoadState = .loading(
                    MapHomeRouteReadingsPolicy.dayKey(for: newDate)
                )
                lastTransitBoardingLiveRefreshAt = nil
                transitBoardingReadingsRevision &+= 1
                nearbyTransitPlacesRevision &+= 1
            } else {
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                recordCurrentPlaybackAlignment()
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
        .onChange(of: model.sleepSessions) { _, _ in
            requestRouteProjectionRefresh(preparingReadings: true)
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.settings.confirmedSleepSpans) { _, _ in
            requestRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.backupRestoreRevision) { _, _ in
            Task {
                await refreshRouteReadings(
                    for: model.selectedDate,
                    forceReload: true
                )
                scheduleExpectedRouteRefresh()
            }
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.liveRouteState.readings.last?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            prepareRouteProjectionReadings()
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if startupCameraPolicy.shouldRestoreZoom(on: phase) {
                restoreInitialMapZoom()
            }
            if phase != .active {
                routeReadingsPreparationTask?.cancel()
                routeReadingsPreparationTask = nil
                routeReadingsPreparationGeneration.advance()
                lastPreparedRouteReadingsSignature = nil
                liveRouteProjectionRefreshTask?.cancel()
                liveRouteProjectionRefreshTask = nil
                expectedRouteRefreshTask?.cancel()
                expectedRouteRefreshTask = nil
                expectedRouteRefreshGeneration &+= 1
                pendingForecastRouteState = nil
                routeDocumentProjectionGate.reset()
                transitPOIRefreshTask?.cancel()
                transitPOIRefreshTask = nil
                transitPOIRefreshGeneration &+= 1
                stopDayPlayback(resetProgress: true)
            } else {
                refreshHomeGrowth(at: .now)
                refreshTimeRailSegments()
                transitBoardingReadingsRevision &+= 1
                scheduleTransitPOIRefresh()
                scheduleExpectedRouteRefresh()
                prepareRouteProjectionReadings()
            }
        }
    }

    @ViewBuilder
    private var map: some View {
        // 지도 provider가 OpenFreeMap(벡터, RPG 등)이면 무료 벡터 렌더러를 쓰고,
        // Apple 스타일이면 기존 MapKit 경로를 유지한다. 경로 재생·마커는 벡터
        // 렌더러도 지원한다(MapHomeVectorRoute/Marker).
        if let vectorStyle = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle {
            vectorMap(style: vectorStyle)
        } else {
            mapKitMap
        }
    }

    private var mapStickersOnMap: [MapSticker] {
        MapStickerDisplayFilterEngine.visibleMapStickers(
            model.snapshot.stickers,
            on: model.selectedDate
        ).filter { $0.point.map(isValid) == true }
    }

    private var mapMemosOnMap: [ActionMemo] {
        guard memoDisplayMode != .hidden else { return [] }
        return MapMemoDisplayFilterEngine.visibleMemos(
            model.snapshot.memos,
            on: model.selectedDate,
            filter: model.settings.mapMemoDisplayFilter,
            selectedPlanIDs: mapMemoRelevantPlanIDs,
            selectedTargetIDs: [],
            through: isDayPlaybackRunning ? routeTimelineDate : nil
        )
        .filter { $0.mapPoint.map(isValid) == true }
        .sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private var mapMemoRelevantPlanIDs: Set<UUID> {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return Set(
            model.snapshot.plans
                .filter { $0.span.start < end && $0.span.end > start }
                .map(\.id)
        )
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
        let selectedDate = timelineSelectionDate
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

    /// 사이드바(선택 시각, 없으면 지금)가 일정 메모 시각의 앞뒤 30분 안에 오면 보여 주는 메모. 가장 가까운 하나.
    private var nearbyScheduleMemo: MapSticker? {
        MapHomeMemoPreviewPolicy.nearest(
            in: model.snapshot.stickers,
            at: timelineSelectionDate,
            selectedDate: model.selectedDate,
            dismissed: dismissedMemoPreviewIDs
        )
    }

    private func scheduleMemoPreview(_ memo: MapSticker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memo.systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: memo.colorHex))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay(Circle().stroke(Color(hex: memo.colorHex), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if let text = memo.memo, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(2)
                }
                Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            .foregroundStyle(Color.tpInk)
            Spacer(minLength: 4)
            Button {
                dismissedMemoPreviewIDs.insert(memo.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color.tpSurface.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.8), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .sticker(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("일정 메모 \(memo.title)", "Schedule memo \(memo.title)"))
        .transition(.opacity)
    }

    // MARK: 통합 메모 표시

    private var memoDisplayMode: MapHomeMemoDisplayMode {
        MapHomeMemoDisplayMode(rawValue: memoDisplayRaw) ?? .all
    }

    /// 시간을 지정하지 않았고 위치도 없는 메모: 왼쪽 위에 큐처럼 쌓인다(오래된 것이 위).
    private var queuedMemos: [ActionMemo] {
        model.snapshot.memos
            .filter { $0.isTimeless == true && $0.mapPoint == nil && !model.isMemoDraft($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 시간은 있고 위치는 없는 메모: 사이드바 시각이 앞뒤 30분 안이면 가장 가까운 하나를 보여 준다.
    private var nearbyTimedMemo: ActionMemo? {
        let calendar = Calendar.autoupdatingCurrent
        let center = timelineSelectionDate
        return model.snapshot.memos
            .filter {
                $0.isTimeless != true && $0.mapPoint == nil && !model.isMemoDraft($0.id)
                    && !dismissedMemoPreviewIDs.contains($0.id)
                    && calendar.isDate($0.occurredAt, inSameDayAs: model.selectedDate)
                    && abs($0.occurredAt.timeIntervalSince(center)) <= 30 * 60
                    && $0.planID == nil
            }
            .min { abs($0.occurredAt.timeIntervalSince(center)) < abs($1.occurredAt.timeIntervalSince(center)) }
    }

    private var memoOverlayStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(queuedMemos.prefix(3)) { memo in
                memoCard(memo, showsTime: false)
            }
            if queuedMemos.count > 3 {
                Text("+\(queuedMemos.count - 3)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .mapHomeGlass(in: Capsule())
            }
            if let timed = nearbyTimedMemo {
                memoCard(timed, showsTime: true)
            }
            if let legacy = nearbyScheduleMemo {
                scheduleMemoPreview(legacy)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 12)
        .padding(.top, 10)
    }

    private func memoCard(_ memo: ActionMemo, showsTime: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: showsTime ? "clock.fill" : "note.text")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                if showsTime {
                    Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .memo(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("메모 \(memo.text)", "Memo \(memo.text)"))
    }

    /// 새 메모: 먼저 임시 초안을 만들고 편집 화면을 연다. 위치·시간은 편집 화면에서 정한다.
    private func addMemo() {
        isMenuOpen = false
        guard let id = model.addMemoDraft(
            text: language.text("새 메모", "New memo"),
            occurredAt: timelineSelectionDate
        ) else { return }
        selectedMapStickerEditor = .newMemo(id)
    }

    /// 편집 화면에서 "위치 추가": 편집 화면을 닫고 지도에서 핀을 고르게 한 뒤 다시 편집 화면으로 돌아온다.
    private func beginMemoLocationPick(_ id: UUID) {
        pendingMemoLocationID = id
        isMenuOpen = false
        isPlacingMapMemo = true
    }

    private func finishMemoLocationPick(apply: Bool) {
        guard let id = pendingMemoLocationID else { return }
        pendingMemoLocationID = nil
        if apply, let center = mapCenterPoint {
            let point = GeoPoint(
                latitude: center.latitude,
                longitude: center.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
            if model.isMemoDraft(id) {
                model.updateMemoDraft(id, text: nil, occurredAt: nil, isTimeless: nil, mapPoint: .some(point))
            } else if let memo = model.snapshot.memos.first(where: { $0.id == id }) {
                _ = model.updateMapMemo(
                    id,
                    text: memo.text,
                    kind: memo.kind,
                    mapPoint: point,
                    occurredAt: memo.occurredAt,
                    isTimeless: memo.isTimeless == true
                )
            }
        }
        selectedMapStickerEditor = model.isMemoDraft(id) ? .newMemo(id) : .memo(id)
    }

    /// 위치 고르기: 지도 가운데에 핀을 두고 지도를 움직여 맞춘다. 취소·확인 버튼은 핀 바로 아래에 붙어 함께 떠 있다.
    private var mapMemoPlacementOverlay: some View {
        ZStack {
            VStack {
                Text(language.text("지도를 움직여 핀 위치를 맞추세요", "Move the map to place the pin"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mapHomeGlass(in: Capsule())
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                Spacer()
            }
            ZStack {
                MapHomePlacementPin()
                    .offset(y: -MapHomePlacementPin.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(spacing: 10) {
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil { finishMemoLocationPick(apply: false) }
                    } label: {
                        Text(language.text("취소", "Cancel"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpInk)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .mapHomeGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil {
                            finishMemoLocationPick(apply: true)
                        } else {
                            addMapMemo()
                        }
                    } label: {
                        Text(pendingMemoLocationID != nil
                             ? language.text("이 위치로", "Use this spot")
                             : language.text("여기에 메모", "Memo here"))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .background(Color.tpReferenceBlue, in: Capsule())
                            .shadow(color: Color.tpReferenceBlue.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addMapMemo() {
        guard let point = mapCenterPoint else { return }
        addMapMemo(
            at: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        )
    }

    private func addMapMemo(at coordinate: CLLocationCoordinate2D) {
        let point = GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let occurredAt = timelineSelectionDate
        let planID = MapMemoLinkEngine
            .plan(containing: occurredAt, in: model.snapshot.plans)?.id
        guard let id = model.addMapMemo(
            text: language.text("새 지도 메모", "New map memo"),
            kind: .idea,
            mapPoint: point,
            planID: planID,
            occurredAt: occurredAt,
            shouldPersist: false
        ) else { return }
        isMenuOpen = false
        selectedMapStickerEditor = .newMemo(id)
    }

    private func addScheduleSticker() {
        let date = timelineSelectionDate
        guard let id = model.addMapSticker(
            title: language.text("새 일정 메모", "New schedule memo"),
            placement: .schedule,
            point: nil,
            planID: selectedSchedulePlanIDs.first,
            occurredAt: date
        ) else { return }
        isMenuOpen = false
        selectedMapStickerEditor = .sticker(id)
    }

    private func runDaySourceTask() async {
        guard model.isBootstrapped, scenePhase == .active else { return }
        let date = model.selectedDate
        guard let prepared = await model.planDaySourceSnapshot(for: date, reusing: dayDataSnapshot),
              !Task.isCancelled, prepared.sourceRevision == model.dayProjectionRevision,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate) else { return }
        if currentDayDataSnapshot == nil {
            dayDataSnapshot = prepared
            dayDataIsPreview = !prepared.isComplete
        }
        routeActualIndex = nil
        refreshHomeGrowth(at: .now)
        refreshTimeRailSegments()
        requestRouteProjectionRefresh(preparingReadings: true)
        requestWBSPlaybackProjectionRefresh()
        scheduleExpectedRouteRefresh()
            }

    private func runRouteReadingsTask() async {
        guard model.isBootstrapped || model.hasPreparedStartupSettings,
              scenePhase == .active else { return }
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let date = model.selectedDate
        if !routeReadingsLoadState.isLoaded(for: date) {
            routeReadingsLoadState = .loading(
                MapHomeRouteReadingsPolicy.dayKey(for: date)
            )
        }
        applyInitialMapFocusIfNeeded()
        reportInitialMapShellReadyIfNeeded(for: date)
        await Task.yield()
        if let preview = await model.startupDayDataPreview(for: date) {
            await refreshRouteReadings(for: date, preloadedDayData: preview, isPreview: true)
        }
        await model.prepareLocalDataForDisplay()
        guard !Task.isCancelled, scenePhase == .active,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if let cached = await model.cachedPlanDayDataSnapshot(for: date) {
            await refreshRouteReadings(
                for: date,
                preloadedDayData: cached,
                isPreview: true
            )
            guard !Task.isCancelled,
                  Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_cached_projection_ready",
                fields: ["duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000))]
            )
        }
        guard !Task.isCancelled else { return }
        async let dayData = model.planDayDataSnapshot(
            for: date,
            forceReload: false,
            refreshRawReadings: true
        )
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        focusMapIfNeeded()
        refreshTimeRailSegments()
        let mapCacheStartedAt = ProcessInfo.processInfo.systemUptime
        let cachedMapDay = await loadMapDayCache(for: date)
        let mapCacheDuration = ProcessInfo.processInfo.systemUptime
            - mapCacheStartedAt
        applyInitialMapFocusIfNeeded()
        guard !Task.isCancelled,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        refreshTimeRailSegments()
        let snapshotWaitStartedAt = ProcessInfo.processInfo.systemUptime
        await refreshRouteReadings(
            for: date,
            preloadedDayData: await dayData,
            cachedMapDay: cachedMapDay
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_date_load_finished",
            fields: [
                "duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000)),
                "map_cache_ms": String(Int(mapCacheDuration * 1_000)),
                "snapshot_wait_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - snapshotWaitStartedAt
                ) * 1_000)),
            ]
        )
        applyInitialMapFocusIfNeeded()
            }

    /// `body`의 수정자 체인이 길어 타입 검사가 느려지지 않도록 `.task`의 id를 따로 계산한다.
    private var daySourceTaskKey: MapHomeDaySourceTaskKey {
        MapHomeDaySourceTaskKey(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            revision: model.dayProjectionRevision,
            isReady: model.isBootstrapped,
            isActive: scenePhase == .active
        )
    }

    private var routeReadingsTaskKey: MapHomeRouteReadingsTaskKey {
        let date = model.selectedDate
        let isToday = Calendar.autoupdatingCurrent.isDateInToday(date)
        let rawRevision: UInt64 = isToday ? 0 : model.rawDataRevision(for: date)
        return MapHomeRouteReadingsTaskKey(
            date: date,
            isBootstrapped: model.isBootstrapped || model.hasPreparedStartupSettings,
            rawDataRevision: rawRevision,
            isSceneActive: scenePhase == .active
        )
    }

    /// Map Home이 실제로 MapLibre 벡터 렌더러로 그려지는지(= Apple 스타일이 아님).
    /// 카메라 이동 명령 경로를 실제 렌더 엔진에 맞춰 고르는 데 쓴다.
    private var rendersVectorMap: Bool {
        model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle != nil
    }

    private var vectorMapContentInsets: UIEdgeInsets {
        .zero
    }

    private func vectorMap(style: MapHomeVectorStyle) -> some View {
        let cameraRevision = mapCameraRevision
        let waypoints = pawprintWaypoints
        let places = placeAnnotations
        let playback = appleMapPlayback
        let displayedSpeed = displayedSpeedMetersPerSecond
        let activeSegments = vectorActiveRouteSegments
        return MapHomeVectorMap(
            style: style,
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            historicalRoutes: recordingShows(\.routes) ? vectorHistoricalRoutes : [],
            activeRoute: recordingShows(\.routes) && activeSegments.isEmpty ? vectorActiveRoute : nil,
            expectedRoutes: recordingShows(\.routes) ? vectorExpectedRoutes : [],
            subwayRoutes: recordingShows(\.routes) ? vectorSubwayRoutes + vectorUserSelectedRoutes : [],
            markers: vectorMapMarkers(waypoints: waypoints),
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            followsHeading: isHeadingMode && userTrackingMode.keepsCameraLocked,
            headingDegrees: -compassRotationDegrees,
            displayedCoordinate: displayedLocationCoordinate,
            onViewportChange: { viewport, isFinal in
                guard cameraRevision == mapCameraRevision else { return }
                applyVectorMapViewport(viewport, isFinal: isFinal)
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onSingleFingerPanEnded: finishDisplayedStickmanViewportProjection,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onSingleTap: { point, positions in
                selectPawprintIfTapped(at: point, waypoints: waypoints, positions: positions)
            },
            activeRouteSegments: recordingShows(\.routes) ? activeSegments : []
        )
        .id(style.rawValue)
        .overlay {
            MapHomeVectorViewportOverlay(store: vectorMapViewportStore) {
                viewport, stickmanPoint in
                vectorMapAnnotationOverlay(
                    style: style,
                    viewport: viewport,
                    stickmanPoint: stickmanPoint,
                    waypoints: waypoints,
                    places: places,
                    playback: playback,
                    displayedSpeed: displayedSpeed
                )
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("mapHomeViewport"))
                .onEnded { tap in
                    presentCatDetailsIfTapped(at: tap.location)
                    dismissMapSearchOverlay()
                },
            including: isSearchDismissable ? .all : .subviews
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
                    shouldFocus = !isPlaybackIntroActive && TimelineInteractionFrameGate.shouldRender(
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
                guard let point = displayedPlaybackFocusPoint else { return }
                focusMap(on: point, using: nil, followsTracking: true)
            } else {
                refreshSelectedTimelineMapPosition(minute: minute, using: nil)
            }
        }
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            // 정수 분이 바뀔 때만이 아니라 재생 틱(30Hz)마다 화랑이를 가운데에 두고 속도에 맞춰 줌을 맞춘다.
            guard isDayPlaybackRunning,
                  TimelineInteractionFrameGate.shouldRender(
                      lastUptime: &lastPlaybackMapFocusUptime,
                      nowUptime: ProcessInfo.processInfo.systemUptime,
                      minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
                  ) else { return }
            recordPlaybackFocusSample()
            guard let point = displayedPlaybackFocusPoint else { return }
            focusMap(on: point, using: nil, followsTracking: true)
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
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onReceive(mapHomeStationaryZoomTicker) { _ in
            advanceStationaryZoomIfNeeded()
        }
    }


    /// 벡터 지도 `fogOfWarOverlay`와 같은 걷어낼 지점(발자국·장소 61pt, 현재 위치 81pt).
    private var appleFogReveals: [MapHomeFogReveal]? {
        guard fogOfWarEnabled else { return nil }
        var reveals = pawprintWaypoints.map { MapHomeFogReveal(coordinate: $0.coordinate, radius: 61) }
        reveals += placeAnnotations.map { MapHomeFogReveal(coordinate: $0.coordinate, radius: 61) }
        if let displayed = displayedLocationCoordinate {
            reveals.append(MapHomeFogReveal(coordinate: displayed, radius: 81))
        }
        return reveals
    }

    private var mapKitMap: some View {
        MapHomeAppleMap(
            style: model.settings.mapDisplayStyle.runtimeStyle,
            accessibilityLabel: language.text("Apple 지도", "Apple map"),
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            viewportCommand: appleViewportCommand,
            routes: appleMapRoutes,
            annotations: appleMapAnnotations,
            playback: appleMapPlayback,
            centersPlayback: selectedTimelineMinute != nil
                || isTimelineInteractionActive
                || userTrackingMode.keepsCameraLocked,
            playbackTargetPoint: currentLocationTargetPoint,
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            fogReveals: appleFogReveals,
            onCameraFrame: { frame, locationPoint, isFinal in
                let now = ProcessInfo.processInfo.systemUptime
                if let rendered = mapCameraFrameProjection.submit(
                    frame,
                    nowUptime: now,
                    force: isFinal
                ), mapCameraFrameProjection.shouldPublishParentReadback(
                    nowUptime: now,
                    isFinal: isFinal
                ) {
                    applyMapCameraFrame(rendered, locationPoint: locationPoint)
                }
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onAnnotationSelected: handleAppleMapAnnotation
        )
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("mapHomeViewport"))
                .onEnded { tap in
                    presentCatDetailsIfTapped(at: tap.location)
                    dismissMapSearchOverlay()
                },
            including: isSearchDismissable ? .all : .subviews
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
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            advanceApplePlaybackZoom()
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting else { return }
            flushDeferredWBSPlaybackProjection()
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onReceive(mapHomeStationaryZoomTicker) { _ in
            advanceStationaryZoomIfNeeded()
        }
    }

    private var vectorHistoricalRoutes: [MapHomeVectorRoute] {
        timelineRouteOverlays.dropLast().flatMap { overlay in
            vectorRoutes(for: overlay, idPrefix: "")
        }
    }

    /// 실제 경로를 속도 그라데이션 구간으로 나눈다. 속도를 모르면 기존 단색 한 줄이다.
    private func vectorRoutes(
        for overlay: MapHomeTimelineRouteOverlay,
        idPrefix: String
    ) -> [MapHomeVectorRoute] {
        let opacity = MapHomeWBSTripStyle.actualRouteOpacity
            * min(max(overlay.opacity, 0), 1)
        guard let slices = mapRenderCache.gradientSlices(
            id: overlay.id,
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            timestamps: overlay.coordinateTimestamps
        ) else {
            return [
                MapHomeVectorRoute(
                    id: idPrefix + overlay.id,
                    coordinates: overlay.coordinates,
                    geometrySignature: overlay.geometrySignature,
                    colorHex: MapHomeWBSTripStyle.actualRouteHex,
                    opacity: opacity
                )
            ]
        }
        return slices.map { slice in
            MapHomeVectorRoute(
                id: idPrefix + slice.id,
                coordinates: slice.coordinates,
                geometrySignature: slice.geometrySignature,
                colorHex: slice.colorHex,
                opacity: opacity
            )
        }
    }

    private var appleActualRoutes: [MapHomeAppleRoute] {
        timelineRouteOverlays.flatMap { overlay -> [MapHomeAppleRoute] in
            let opacity = MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
            guard let slices = mapRenderCache.gradientSlices(
                id: overlay.id,
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                timestamps: overlay.coordinateTimestamps
            ) else {
                return [
                    MapHomeAppleRoute(
                        id: "timeline-\(overlay.id)",
                        coordinates: overlay.coordinates,
                        geometrySignature: overlay.geometrySignature,
                        colorHex: MapHomeWBSTripStyle.actualRouteHex,
                        opacity: opacity,
                        phase: .actual,
                        transport: nil
                    )
                ]
            }
            return slices.map { slice in
                MapHomeAppleRoute(
                    id: "timeline-\(slice.id)",
                    coordinates: slice.coordinates,
                    geometrySignature: slice.geometrySignature,
                    colorHex: slice.colorHex,
                    opacity: opacity,
                    phase: .actual,
                    transport: nil
                )
            }
        }
    }

    private var appleMapRoutes: [MapHomeAppleRoute] {
        var routes = appleActualRoutes

        routes += subwayRouteOverlays.compactMap { overlay in
            guard overlay.coordinates.count >= 2 else { return nil }
            return MapHomeAppleRoute(
                id: "subway-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: overlay.estimated
                    ? MapHomeWBSTripStyle.forecastRouteOpacity
                    : MapHomeWBSTripStyle.actualRouteOpacity,
                phase: overlay.estimated ? .forecast : .actual,
                transport: .transit
            )
        }

        routes += appleMapForecastRoutes
        routes += appleUserSelectedRoutes
        return routes.filter { $0.coordinates.count >= 2 }
    }

    /// 사용자가 확정한 예상 경로와 지금 선택한 예상 경로의 선. 발자국이 이 경로 위에 그려지므로 선도 같은 좌표로 그린다
    /// (벡터 지도의 `vectorUserSelectedRoutes`와 같은 내용).
    private var appleUserSelectedRoutes: [MapHomeAppleRoute] {
        var routes = confirmedPredictedRoutes.map { route -> MapHomeAppleRoute in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeAppleRoute(
                id: "confirmed-predicted-\(route.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: 0.95,
                phase: .actual,
                transport: nil
            )
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeAppleRoute(
                id: "selected-\(selectedPredictedRoute.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800",
                opacity: 1,
                phase: .actual,
                transport: nil
            ))
        }
        return routes
    }

    private var appleMapForecastRoutes: [MapHomeAppleRoute] {
        let expected = displayedExpectedRouteOverlays
        let generated = displayedWBSGeneratedRouteOverlays
        let fallback = expected.map { overlay in
            MapHomeAppleRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: MapHomeAppleRouteTransport(mode: overlay.mode)
            )
        } + generated.map { overlay in
            MapHomeAppleRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: overlay.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        guard let projection = wbsPlaybackProjection else { return fallback }
        let expectedLegIDs = Set(expected.map { "movement-\($0.id.uuidString)" })
        let generatedLegIDs = Set(generated.map(\.id))
        let dottedLegIDs = expectedLegIDs.union(generatedLegIDs)
        let baseSignatures = Dictionary(
            fallback.map { ($0.id, $0.geometrySignature) },
            uniquingKeysWith: { first, _ in first }
        )
        let cutoff = routeOverlayCutoff
        let projected = projection.legs.compactMap { leg -> MapHomeAppleRoute? in
            guard dottedLegIDs.contains(leg.id),
                  leg.routePhase == .forecast,
                  leg.activity == .movement,
                  let coordinates = visibleForecastCoordinates(
                    for: leg,
                    through: cutoff
                  ) else { return nil }
            let id: String
            if expectedLegIDs.contains(leg.id) {
                id = "expected-\(String(leg.id.dropFirst("movement-".count)))"
            } else {
                id = "wbs-\(leg.id)"
            }
            guard let baseSignature = baseSignatures[id] else { return nil }
            return MapHomeAppleRoute(
                id: id,
                coordinates: coordinates,
                geometrySignature: MapHomeRouteGeometrySignature.derived(
                    from: baseSignature,
                    coordinates: coordinates
                ),
                colorHex: leg.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: leg.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        return projected
    }

    private func visibleForecastCoordinates(
        for leg: MapHomeWBSPlaybackLeg,
        through cutoff: Date
    ) -> [CLLocationCoordinate2D]? {
        guard cutoff > leg.startDate,
              leg.coordinates.count >= 2 else { return nil }
        let coordinates = leg.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard cutoff < leg.endDate else { return coordinates }
        let duration = leg.endDate.timeIntervalSince(leg.startDate)
        guard duration > 0 else { return coordinates }
        let fraction = min(
            max(cutoff.timeIntervalSince(leg.startDate) / duration, 0),
            1
        )
        return MapHomeExpectedRouteOverlay.prefixByDistance(
            coordinates,
            fraction: fraction,
            segmentLengths: leg.segmentLengths
        )
    }

    private var appleMapAnnotations: [MapHomeAppleAnnotation] {
        var annotations = temporaryLocationAnnotations.map { location in
            MapHomeAppleAnnotation(
                id: "temporary-\(location.id.uuidString)",
                coordinate: location.coordinate,
                kind: .temporary(
                    stationName: location.stationName,
                    title: language.text("임시 위치", "Temporary")
                ),
                accessibilityLabel: language.text(
                    "\(location.stationName) 지하철 임시 위치",
                    "\(location.stationName) temporary subway location"
                ),
                isInteractive: false
            )
        }
        annotations += placeAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "place-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .place(place),
                accessibilityLabel: place.destination == .user
                    ? language.text(
                        "\(place.name) 사용자 위치 메뉴",
                        "\(place.name) user location menu"
                    )
                    : language.text(
                        "\(place.name), 레벨 \(place.floor ?? 1)",
                        "\(place.name), level \(place.floor ?? 1)"
                    ),
                isInteractive: place.destination == .user
            )
        }
        annotations += transitAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "transit-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .transit(place),
                accessibilityLabel: language.text(
                    "\(place.name) 사용자 위치 메뉴",
                    "\(place.name) user location menu"
                ),
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
                accessibilityLabel: language.text(
                    "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                    "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                ),
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
                accessibilityLabel: language.text(
                    "\(sticker.title) 메모 스티커",
                    "\(sticker.title) memo sticker"
                ),
                isInteractive: isStickerMode
            )
        }
        annotations += mapMemosOnMap.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeAppleAnnotation(
                id: "memo-\(memo.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .memo(memo),
                accessibilityLabel: language.text(
                    "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                    "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                ),
                isInteractive: true
            )
        }
        if let selectedSearchPin {
            annotations.append(
                MapHomeAppleAnnotation(
                    id: "search-pin",
                    coordinate: selectedSearchPin.coordinate,
                    kind: .search(selectedSearchPin),
                    accessibilityLabel: language.text(
                        "\(selectedSearchPin.title) 위치 추가",
                        "Add \(selectedSearchPin.title) location"
                    ),
                    isInteractive: true
                )
            )
        }
        for waypoint in pawprintWaypoints {
            let isSelectedRoute = waypoint.isPredicted
                && waypoint.predictedRoute?.id == selectedPredictedRoute?.id
            let isInteractive = waypoint.predictedRoute != nil
                || (waypoint.timestamp != nil && !waypoint.isPredicted)
            annotations.append(
                MapHomeAppleAnnotation(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate,
                    kind: .pawprint(MapHomeApplePawprint(
                        index: waypoint.index, angle: waypoint.angle,
                        isPredicted: waypoint.isPredicted, isSelectedRoute: isSelectedRoute,
                        speedMetersPerSecond: waypoint.speedMetersPerSecond
                    )),
                    accessibilityLabel: waypoint.predictedRoute != nil
                        ? language.text("예상 경로 선택", "Select predicted route")
                        : waypoint.timestamp.map {
                            language.text("기록 발자국 ", "Recorded paw ")
                                + $0.formatted(date: .omitted, time: .shortened)
                        } ?? "",
                    isInteractive: isInteractive
                )
            )
        }
        return annotations
    }

    private var appleMapPlayback: MapHomeApplePlayback? {
        guard !isDisplayedCatAtHome,
              let coordinate = displayedLocationCoordinate else { return nil }
        let heading: CLLocationDirection
        let phase: MapHomeAppleRoutePhase
        let animationPhase: Int?
        let cameraCoordinate: CLLocationCoordinate2D
        if selectedPawprintPoint != nil {
            heading = CLLocationDirection(wbsPlaybackFrame?.direction.rawValue ?? 0) * 45
            phase = .actual
            animationPhase = wbsPlaybackFrame?.stickmanFrameIndex
            cameraCoordinate = coordinate
        } else if let frame = wbsPlaybackFrame {
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
                coordinates: route.coordinates,
                segmentLengths: route.segmentLengths
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
        let action = displayedStickmanAction
        return MapHomeApplePlayback(
            coordinate: coordinate,
            cameraCoordinate: cameraCoordinate,
            headingDegrees: heading,
            action: action,
            accessibilityLabel: "\(displayedLocationAccessibilityLabel) · \(action.title)",
            phase: phase,
            followsUserLocation: selectedTimelineMinute == nil,
            equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
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
            if place.destination == .home {
                isDaySummaryPresented = true
                return
            }
            guard place.destination == .user else { return }
            selectedUserLocation = .frequentPlace(place.id)
        case .transit(let place):
            selectedUserLocation = .transit(place.id)
        case .boarding(let candidate):
            selectedTransitBoardingCandidate = candidate
        case .sticker(let sticker):
            selectedMapStickerEditor = .sticker(sticker.id)
        case .memo(let memo):
            selectedMapStickerEditor = .memo(memo.id)
        case .search:
            isSearchPinMenuPresented = true
        case .pawprint(let paw):
            if let waypoint = pawprintWaypoints.first(where: { $0.index == paw.index }) {
                selectPawprint(waypoint)
            }
        }
    }

    private var vectorActiveRouteSegments: [MapHomeVectorRoute] {
        guard let overlay = timelineRouteOverlays.last else { return [] }
        let routes = vectorRoutes(for: overlay, idPrefix: "active-")
        return routes.count == 1 && routes[0].id == "active-" + overlay.id
            ? [] : routes
    }

    private var vectorActiveRoute: MapHomeVectorRoute? {
        guard let overlay = timelineRouteOverlays.last else { return nil }
        return MapHomeVectorRoute(
            id: "active-\(overlay.id)",
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            colorHex: MapHomeWBSTripStyle.actualRouteHex,
            opacity: MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
        )
    }

    private var vectorExpectedRoutes: [MapHomeVectorRoute] {
        let expected = displayedExpectedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let generated = displayedWBSGeneratedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let estimatedSubway: [MapHomeVectorRoute] = subwayRouteOverlays.compactMap {
            overlay -> MapHomeVectorRoute? in
            guard overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-estimated-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        return expected + generated + estimatedSubway
    }

    private var vectorSubwayRoutes: [MapHomeVectorRoute] {
        subwayRouteOverlays.compactMap { overlay in
            guard !overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity
            )
        }
    }

    private func vectorMapMarkers(waypoints: [PawprintWaypoint]) -> [MapHomeVectorMarker] {
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
        markers += photoClusters.map {
            MapHomeVectorMarker(id: vectorPhotoMarkerID($0.id), coordinate: $0.coordinate)
        }
        markers += mapMemosOnMap.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapMemoMarkerID(memo.id),
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
        for waypoint in waypoints {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate
                )
            )
        }
        return markers
    }

    private var vectorPlayerHeading: CLLocationDirection {
        appleMapPlayback?.headingDegrees ?? 0
    }

    private func predictedRoute(source: String, travelID: UUID? = nil, mode: TravelMode,
                                span: TimeSpan, coordinates: [CLLocationCoordinate2D]) -> MapPredictedRoute {
        MapPredictedRoute(source: source, travelID: travelID, mode: mode, span: span,
            coordinates: coordinates.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude,
                altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1) })
    }

    private func predictedRoute(for overlay: MapHomeExpectedRouteOverlay) -> MapPredictedRoute {
        predictedRoute(source: overlay.mode == .subway || overlay.mode == .train ? "rail" : "forecast",
            travelID: overlay.segmentID, mode: overlay.mode,
            span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate), coordinates: overlay.coordinates)
    }

    private func predictedRoute(for overlay: MapHomeWBSGeneratedRouteOverlay) -> MapPredictedRoute {
        let mode = overlay.mode ?? .walking
        let matching = currentDayDataSnapshot?.travel.filter {
            abs($0.span.start.timeIntervalSince(overlay.departureDate)) <= 1
                && abs($0.span.end.timeIntervalSince(overlay.arrivalDate)) <= 1
        } ?? []
        return predictedRoute(source: mode == .subway || mode == .train ? "rail" : "forecast",
            travelID: matching.count == 1 ? matching[0].id : nil,
            mode: mode, span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate),
            coordinates: overlay.coordinates)
    }

    private func predictedRoute(for overlay: MapHomeSubwayRouteOverlay) -> MapPredictedRoute? {
        guard let travel = currentDayDataSnapshot?.travel.first(where: { $0.id == (overlay.travelID ?? overlay.id) }) else { return nil }
        let points = travel.subwayRoute?.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? overlay.coordinates
        return predictedRoute(source: "rail", travelID: travel.id, mode: travel.mode,
            span: travel.span, coordinates: points.count >= 2 ? points : overlay.coordinates)
    }

    private func hasRouteDecision(_ route: MapPredictedRoute) -> Bool {
        model.snapshot.settings.predictedRouteDecisions.contains { $0.matches(route) }
    }

    private var predictedMapRoutes: [MapPredictedRoute] {
        let cutoff = routeOverlayCutoff
        var routes = expectedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
        routes += wbsGeneratedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
        routes += subwayRouteOverlays.compactMap { predictedRoute(for: $0) }
        routes += MapHomeGPSGapPredictionPolicy.predictedGaps(from: normalizedRouteReadings, through: cutoff).compactMap { gap in
            guard let first = gap.start.point, let last = gap.end.point else { return nil }
            return MapPredictedRoute(source: "gps-gap", travelID: nil, mode: .walking,
                span: TimeSpan(start: gap.start.timestamp, end: gap.end.timestamp),
                coordinates: [first] + gap.coordinates.map {
                    GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0,
                        horizontalAccuracy: -1, verticalAccuracy: -1)
                } + [last])
        }
        var seen = Set<String>()
        return routes.filter { $0.isValid && !hasRouteDecision($0) && seen.insert($0.id).inserted }
    }

    private var confirmedPredictedRoutes: [MapPredictedRoute] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return model.snapshot.settings.predictedRouteDecisions.filter {
            !$0.isDeleted && $0.route.isValid
                && $0.route.span.start < end && $0.route.span.end > start
        }.map(\.route)
    }

    private func coordinates(for route: MapPredictedRoute, through cutoff: Date? = nil) -> [CLLocationCoordinate2D] {
        let points = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let cutoff else { return points }
        let fraction = min(1, max(0, cutoff.timeIntervalSince(route.span.start) / route.span.duration))
        guard fraction > 0 else { return [] }
        return MapHomeExpectedRouteOverlay.prefixByDistanceResult(points, fraction: fraction,
            segmentLengths: MapHomeExpectedRoutePlaybackMath.segmentLengths(for: points)).coordinates
    }

    private var vectorUserSelectedRoutes: [MapHomeVectorRoute] {
        var routes = confirmedPredictedRoutes.map { route in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeVectorRoute(id: "confirmed-predicted-\(route.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex, opacity: 0.95)
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeVectorRoute(id: "selected-\(selectedPredictedRoute.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800", opacity: 1))
        }
        return routes
    }

    private func presentCatDetailsIfTapped(at tapPoint: CGPoint) {
        guard pawprintTarget(at: tapPoint, waypoints: pawprintWaypoints) == nil else { return }
        if let stickmanPoint = vectorMapViewportStore.stickmanPoint ?? displayedStickmanViewportPoint,
           MapHomeCatTapRouting.shouldPresentCatDetails(
               tapPoint: tapPoint,
               locationPoint: stickmanPoint,
               isAtHome: isDisplayedCatAtHome
           ) {
            selectedMarkerInfo = .cat(displayedStickmanAction)
            return
        }
        if isHomeSummaryTapped(at: tapPoint) { isDaySummaryPresented = true }
    }

    /// 집 아이콘·레벨 라벨 탭. 핀 안쪽 제스처에 기대지 않고 지도 단위 탭에서 집 핀 좌표로 판정한다.
    private func isHomeSummaryTapped(at tapPoint: CGPoint) -> Bool {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let viewport = vectorMapViewportStore.viewport,
              let pinPoint = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return false }
        return MapHomeCatTapRouting.hitsHomeSummary(
            tapPoint: tapPoint,
            pinPoint: pinPoint,
            showsCatAtHome: isDisplayedCatAtHome
        )
    }

    private func pawprintTarget(
        at point: CGPoint,
        waypoints: [PawprintWaypoint],
        positions: [String: CGPoint]? = nil
    ) -> PawprintWaypoint? {
        guard let positions = positions ?? vectorMapViewportStore.viewport?.markerPoints else { return nil }
        let targets = waypoints.compactMap { waypoint -> MapHomePawprintTapTarget? in
            guard let position = positions[vectorPawprintMarkerID(waypoint.index)]
            else { return nil }
            return MapHomePawprintTapTarget(
                id: waypoint.index, point: position,
                timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
                routeID: waypoint.predictedRoute?.id,
                routeSpan: waypoint.predictedRoute?.span
            )
        }
        guard let id = MapHomePawprintInteractionPolicy.nearestTarget(
            to: point, targets: targets, selectedDate: model.selectedDate
        ) else { return nil }
        return waypoints.first { $0.index == id }
    }

    private func selectPawprintIfTapped(
        at point: CGPoint,
        waypoints: [PawprintWaypoint],
        positions: [String: CGPoint]
    ) {
        guard let waypoint = pawprintTarget(at: point, waypoints: waypoints, positions: positions)
        else { return }
        selectPawprint(waypoint)
    }

    private func selectPawprint(_ waypoint: PawprintWaypoint) {
        if let route = waypoint.predictedRoute {
            stopDayPlayback(resetProgress: false)
            recordUserMapAdjustment()
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            setUserTrackingMode(.idle)
            selectedPredictedRoute = route
            dismissMapSearchOverlay()
            return
        }
        guard let selection = MapHomePawprintInteractionPolicy.selection(
            timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
            selectedDate: model.selectedDate
        ) else { return }
        stopDayPlayback(resetProgress: true)
        isTimelineInteractionActive = false
        recordUserMapAdjustment()
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        setUserTrackingMode(.idle)
        isTimelineSelectionPinned = true
        selectedTimelineMinute = selection.minute
        selectedPawprintTimestamp = selection.timestamp
        selectedPawprintCoordinate = waypoint.coordinate
        _ = refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        focusMap(on: wbsGeoPoint(waypoint.coordinate), using: nil, followsTracking: true)
        dismissMapSearchOverlay()
    }

    private func vectorMapAnnotationOverlay(
        style: MapHomeVectorStyle,
        viewport: MapHomeVectorViewport?,
        stickmanPoint: CGPoint?,
        waypoints: [PawprintWaypoint],
        places: [MapHomePlaceAnnotation],
        playback: MapHomeApplePlayback?,
        displayedSpeed: Double?
    ) -> some View {
        ZStack {
            fogOfWarOverlay(viewport: viewport, waypoints: waypoints, places: places, stickmanPoint: stickmanPoint)
            homeLandOverlay(viewport: viewport)
            ForEach((recordingShows(\.footprints) ? waypoints : []).sorted {
                $0.isPredicted != $1.isPredicted ? $0.isPredicted : $0.index < $1.index
            }) { waypoint in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPawprintMarkerID(waypoint.index)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .center) {
                        if let timestamp = waypoint.timestamp, !waypoint.isPredicted {
                            pawprintImage(waypoint)
                                .accessibilityLabel(
                                    Text(language.text("기록 발자국 ", "Recorded paw "))
                                        + Text(timestamp, style: .time)
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else if waypoint.predictedRoute != nil {
                            pawprintImage(waypoint)
                                .accessibilityLabel(language.text("예상 경로 선택", "Select predicted route"))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else {
                            pawprintImage(waypoint).accessibilityHidden(true)
                        }
                    }
                }
            }
            ForEach(temporaryLocationAnnotations) { location in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTemporaryMarkerID(location.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
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
                        .allowsHitTesting(false)
                    }
                }
            }

            ForEach(places) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPlaceMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(
                        point: point,
                        anchor: MapHomePlaceAnnotationLayout.vectorAnchor
                    ) {
                        if place.destination == .user {
                            MapHomePlacePin(
                                name: place.name,
                                floor: place.floor,
                                destination: place.destination,
                                growthLevel: place.growthLevel,
                                isLeapDay: place.isLeapDay,
                                growthStatus: place.growthStatus,
                                isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                growthStreak: place.growthStreak,
                                pendingWeeklyRewards: place.pendingWeeklyRewards,
                                showsCatAtHome: place.isCatAtHome,
                                catAction: place.catAction,
                                equippedAccessoryID: place.equippedAccessoryID
                            )
                            .fixedSize()
                            // simultaneousGesture: 탭으로 사용자 위치 메뉴를 열되
                            // 지도 팬·핀치줌은 랜드마크 위에서도 그대로 통과.
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    selectedUserLocation = .frequentPlace(place.id)
                                }
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(
                                language.text(
                                    place.name + " 사용자 위치 메뉴",
                                    place.name + " user location menu"
                                )
                            )
                        } else {
                            if place.destination == .home {
                                MapHomePlacePin(
                                    name: place.name,
                                    floor: place.floor,
                                    destination: place.destination,
                                    growthLevel: place.growthLevel,
                                    isLeapDay: place.isLeapDay,
                                    growthStatus: place.growthStatus,
                                    isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                    growthStreak: place.growthStreak,
                                    pendingWeeklyRewards: place.pendingWeeklyRewards,
                                    showsCatAtHome: place.isCatAtHome,
                                    catAction: place.catAction,
                                    equippedAccessoryID: place.equippedAccessoryID,
                                    weatherBadge: place.weatherBadge,
                                    onOpenDaySummary: { isDaySummaryPresented = true }
                                )
                                .fixedSize()
                                .accessibilityAddTraits(.isButton)
                            } else {
                                MapHomePlacePin(
                                    name: place.name,
                                    floor: place.floor,
                                    destination: place.destination,
                                    growthLevel: place.growthLevel,
                                    isLeapDay: place.isLeapDay,
                                    growthStatus: place.growthStatus,
                                    isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                    growthStreak: place.growthStreak,
                                    pendingWeeklyRewards: place.pendingWeeklyRewards,
                                    showsCatAtHome: place.isCatAtHome,
                                    catAction: place.catAction,
                                    equippedAccessoryID: place.equippedAccessoryID
                                )
                                .fixedSize()
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        selectedMarkerInfo = .landmark(place.destination)
                                    }
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(
                                    language.text(
                                        "\(place.name), 레벨 \(place.floor ?? 1)",
                                        "\(place.name), level \(place.floor ?? 1)"
                                    )
                                )
                            }
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

            ForEach(photoClusters) { cluster in
                if let info = photoPinInfo(for: cluster),
                   let point = vectorPoint(in: viewport, for: vectorPhotoMarkerID(cluster.id)) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            photoAlbumSelection = MapHomePhotoAlbumSelection(
                                id: cluster.id,
                                moments: cluster.moments
                            )
                        } label: {
                            MapHomePhotoPin(
                                coverID: info.coverID,
                                count: info.count,
                                isHighlighted: info.highlighted
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!isDayPlaybackRunning && !isScreenRecording)
                    }
                    .animation(.easeOut(duration: 0.25), value: info.coverID)
                }
            }

            ForEach(recordingShows(\.mapMemos) ? mapMemosOnMap : []) { memo in
                if let projected = vectorPoint(
                    in: viewport,
                    for: vectorMapMemoMarkerID(memo.id)
                ) {
                    MapHomeProjectedAnnotation(point: projected, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .memo(memo.id)
                        } label: {
                            MapHomeMapMemoMarker(memo: memo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text(
                                "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                                "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                            )
                        )
                    }
                }
            }

            if selectedTimelineMinute != nil,
               !isDisplayedCatAtHome,
               let point = vectorPoint(in: viewport, for: vectorDisplayedMarkerID) {
                MapHomeVectorPlayerMarker(
                    heading: playback?.headingDegrees ?? 0,
                    backgroundHex: style.backgroundHex
                )
                    .position(x: point.x, y: point.y + 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let playback,
               recordingShows(\.cat),
               let point = stickmanPoint {
                MapHomeStickmanMarker(
                    action: playback.action,
                    animationPhase: playback.stickmanAnimationPhase,
                    routePhase: playback.phase == .forecast
                        ? .forecast
                        : .actual,
                    speedMetersPerSecond: displayedSpeed,
                    equippedAccessoryID: homeGrowthHistory.season.equippedAccessory
                    )
                    .position(
                        x: point.x
                            + MapHomeStickmanAnnotationLayout.centerOffset.x,
                        y: point.y
                            + MapHomeStickmanAnnotationLayout.centerOffset.y
                    )
                    .zIndex(MapHomeLayerPriority.stickman)
                    // 화랑이 위에서도 지도 팬·핀치줌이 최우선이 되도록 마커는
                    // 히트테스트에서 제외한다(다른 마커와 동일). UIKit 지도 위의
                    // SwiftUI simultaneousGesture는 드래그를 지도로 흘려보내지
                    // 못해 고양이 주변 터치를 삼켰다. 상세는 중앙 상단 탐험 HUD로
                    // 연다.
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(
                        "\(playback.accessibilityLabel), \(language.text("설명 보기","Show info"))"
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
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
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

    /// 스타크래프트식 안개 탐험(fog of war). 지도 전체를 어둡게 덮고,
    /// 내가 이동한 경로(발자국 waypoint)와 현재 위치·랜드마크 주변만
    /// 원형으로 걷어내 "탐험한 곳만 밝은" 느낌을 준다. destinationOut
    /// 블렌드로 구멍을 뚫으므로 아래 지도 타일이 그 자리에서만 드러난다.
    @ViewBuilder
    private func fogOfWarOverlay(
        viewport: MapHomeVectorViewport?,
        waypoints: [PawprintWaypoint],
        places: [MapHomePlaceAnnotation],
        stickmanPoint: CGPoint? = nil
    ) -> some View {
        if fogOfWarEnabled, let viewport {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black.opacity(0.55)))
                context.blendMode = .destinationOut
                var reveals = waypoints.compactMap {
                    viewport.markerPoints[vectorPawprintMarkerID($0.index)]
                }.map { ($0, CGFloat(61)) }
                reveals += places.compactMap {
                    viewport.markerPoints[vectorPlaceMarkerID($0.id)]
                }.map { ($0, CGFloat(61)) }
                if let point = MapHomeFogRevealPolicy.currentLocationPoint(
                    stickmanPoint: stickmanPoint,
                    viewportPoint: viewport.markerPoints[vectorDisplayedMarkerID]
                ) {
                    reveals.append((point, 81))
                }
                for (point, radius) in reveals {
                    let rect = CGRect(x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2)
                    guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [.black, .black.opacity(0.7), .clear]),
                        center: point, startRadius: 0, endRadius: radius))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

        private var vectorDisplayedMarkerID: String { "displayed-location" }
    private var vectorSearchMarkerID: String { "search-location" }

    private func vectorTemporaryMarkerID(_ id: UUID) -> String {
        "temporary-\(id.uuidString)"
    }

    private struct PawprintWaypoint: Identifiable {
        let index: Int
        let coordinate: CLLocationCoordinate2D
        let angle: Double
        let isPredicted: Bool
        let timestamp: Date?
        var predictedRoute: MapPredictedRoute? = nil
        var speedMetersPerSecond: Double? = nil
        var id: Int { index }
    }

    private func pawprintImage(_ waypoint: PawprintWaypoint) -> some View {
        Image(systemName: "pawprint.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(waypoint.predictedRoute?.id == selectedPredictedRoute?.id && waypoint.isPredicted
                ? Color.orange : waypoint.isPredicted ? Color.gray.opacity(0.68)
                : MapHomePawprintSpeedColor.color(forMetersPerSecond: waypoint.speedMetersPerSecond))
            .rotationEffect(.degrees(waypoint.angle))
            .allowsHitTesting(false)
    }

    /// 실제 경로의 좌표와 시각을 함께 샘플링하며 예상 발자국에는 시각을 부여하지 않는다.
    private var pawprintWaypoints: [PawprintWaypoint] {
        let segments = timelineRouteOverlays
            .filter { $0.coordinates.count >= 2 }
        let hardCap = MapHomePawprintInteractionPolicy.markerLimit
        let predictedSegments = predictedMapRoutes.map { route in
            (route: route, points: MapHomeGPSGapPredictionPolicy.predictedRailCoordinates(
                along: coordinates(for: route, through: routeOverlayCutoff)))
        }
        let confirmedSegments = confirmedPredictedRoutes.map { route in
            let samples = MapHomeGPSGapPredictionPolicy.predictedRailCoordinates(along: coordinates(for: route))
            let timestamps = samples.indices.map { index in
                route.span.start.addingTimeInterval(route.span.duration
                    * Double(index) / Double(max(1, samples.count - 1)))
            }
            let visible = samples.indices.filter {
                timestamps[$0] <= routeOverlayCutoff && Calendar.autoupdatingCurrent
                    .isDate(timestamps[$0], inSameDayAs: model.selectedDate)
            }
            return (route: route, points: visible.map { samples[$0] }, timestamps: visible.map { timestamps[$0] })
        }
        let inferredCounts = confirmedSegments.map { $0.points.count } + predictedSegments.map { $0.points.count }
        let recordedSamples = MapHomePawprintInteractionPolicy.sampleIndices(
            segments: segments.map { MapHomePawprintTrace(coordinates: $0.coordinates, timestamps: $0.coordinateTimestamps) },
            limit: MapHomePawprintInteractionPolicy.recordedBudget(inferredDemand: inferredCounts.reduce(0, +))
        )
        var result: [PawprintWaypoint] = []
        for (segment, indices) in zip(segments, recordedSamples) {
            let coords = segment.coordinates
            for i in indices {
                let c = coords[i]
                let nextIndex = min(coords.count - 1, i + 1)
                let n = coords[nextIndex]
                let a = (n.longitude - c.longitude == 0 && n.latitude - c.latitude == 0)
                    ? (i > 0
                        ? atan2(c.longitude - coords[i - 1].longitude,
                                c.latitude - coords[i - 1].latitude) * 180 / .pi
                        : 0)
                    : atan2(n.longitude - c.longitude, n.latitude - c.latitude) * 180 / .pi
                let previousIndex = max(0, i - 1)
                result.append(
                    PawprintWaypoint(
                        index: result.count,
                        coordinate: c,
                        angle: a,
                        isPredicted: false,
                        timestamp: segment.coordinateTimestamps[i],
                        speedMetersPerSecond: MapHomePawprintSpeedColor.windowedSpeed(
                            coordinates: coords,
                            timestamps: segment.coordinateTimestamps,
                            index: i
                        ) ?? MapHomePawprintSpeedColor.speed(
                            from: coords[previousIndex],
                            at: segment.coordinateTimestamps[previousIndex],
                            to: n,
                            at: segment.coordinateTimestamps[nextIndex]
                        )
                    )
                )
            }
        }
        let inferredBudgets = MapHomePawprintInteractionPolicy.distributedCounts(sampleCounts: inferredCounts,
            latestTimestamps: confirmedSegments.map { $0.route.span.end } + predictedSegments.map { $0.route.span.end },
            limit: hardCap - result.count)
        for (segmentIndex, segment) in confirmedSegments.enumerated() {
            // 확인된 이동은 구간 전체 길이를 시간으로 나눈 평균 속도를 쓴다.
            var segmentSpeed: Double?
            if let firstPoint = segment.points.first, let lastPoint = segment.points.last,
               let firstDate = segment.timestamps.first, let lastDate = segment.timestamps.last {
                let length = zip(segment.points, segment.points.dropFirst()).reduce(0.0) { sum, pair in
                    sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                        .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
                }
                let seconds = lastDate.timeIntervalSince(firstDate)
                if seconds > 0, firstPoint.latitude.isFinite, lastPoint.latitude.isFinite {
                    segmentSpeed = length / seconds
                }
            }
            for index in MapHomePawprintInteractionPolicy.spreadIndices(
                count: segment.points.count, limit: inferredBudgets[segmentIndex]
            ) {
                let point = segment.points[index]
                result.append(PawprintWaypoint(index: result.count,
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    angle: 0, isPredicted: false, timestamp: segment.timestamps[index],
                    speedMetersPerSecond: segmentSpeed))
            }
        }
        for (segmentIndex, segment) in predictedSegments.enumerated() {
            let points = segment.points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            for index in MapHomePawprintInteractionPolicy.spreadIndices(
                count: points.count, limit: inferredBudgets[confirmedSegments.count + segmentIndex]
            ) {
                let point = points[index]
                let previous = points[max(0, index - 1)]
                let next = points[min(points.count - 1, index + 1)]
                let angle = atan2(
                    next.longitude - previous.longitude,
                    next.latitude - previous.latitude
                ) * 180 / .pi
                result.append(
                    PawprintWaypoint(
                        index: result.count,
                        coordinate: point,
                        angle: angle,
                        isPredicted: true,
                        timestamp: nil,
                        predictedRoute: segment.route
                    )
                )
            }
        }
        return result
    }

    private func vectorPawprintMarkerID(_ index: Int) -> String {
        "pawprint-\(index)"
    }

    // MARK: 집 주변 땅(지도)

    /// 붙일 땅(타일)이 남아 있고, 카메라가 집 300m 안에서 400m 이하로 가까울 때. 타일을 추가하는 동안만 벡터 스타일이 필요하다.
    private var isNearHomeLand: Bool {
        guard autoLandStyleEnabled,
              let camera = visibleMapCamera, camera.distance <= 400,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return false }
        let season = homeGrowthHistory.season
        let placed = Set((season.landPlotPlacements ?? []).map(\.plotID))
        guard season.landPlots.contains(where: { !placed.contains($0) }) else { return false }
        let center = GeoPoint(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        return distanceMeters(center, home) <= 300
    }

    /// 타일을 추가할 때 애플 지도 스타일이면 벡터 스타일로 바꾸고, 다 붙이거나 집에서 벗어나면 원래 스타일로 되돌린다.
    /// 사용자가 그 사이에 직접 스타일을 바꿨다면 되돌리지 않는다.
    private func applyAutoLandStyle(near: Bool) {
        let current = model.settings.mapDisplayStyle.runtimeStyle
        if near {
            guard autoLandStyleState.isEmpty, current.mapHomeVectorStyle == nil else { return }
            let target = MapDisplayStyle.mapLibreLight
            autoLandStyleState = "\(current.rawValue)|\(target.rawValue)"
            model.setMapDisplayStyle(target)
        } else {
            let parts = autoLandStyleState.split(separator: "|").map(String.init)
            autoLandStyleState = ""
            guard parts.count == 2, parts[1] == current.rawValue,
                  let previous = MapDisplayStyle(rawValue: parts[0]) else { return }
            model.setMapDisplayStyle(previous)
        }
    }

    /// 땅 한 칸의 실제 크기(m). 최대 확대(카메라 거리 80m, 1점≈0.06m) 기준으로 한 칸이 약 416pt가 된다.
    private static let landCellMeters = 25.0

    /// 집 주변에 이어 붙인 땅을 지도 위에 그린다(최대 확대에 가까울수록 크게). 붙일 땅이 남아 있으면
    /// 이을 수 있는 빈 칸이 점선 "+"로 나오고, 눌러서 이어 붙인다. 벡터 지도 스타일에서만 그린다.
    @ViewBuilder
    private func homeLandOverlay(viewport: MapHomeVectorViewport?) -> some View {
        if let layout = homeLandLayout(viewport: viewport) {
            let season = homeGrowthHistory.season
            let placements = season.landPlotPlacements ?? []
            let nextPlot = season.landPlots.first { id in !placements.contains { $0.plotID == id } }
            let candidates = nextPlot == nil ? [] : MapHomeGrowthPolicy.placementCandidates(in: season)
            ZStack {
                ForEach(placements) { placement in
                    RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                        .fill(Color.tpPastelMint.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                                .stroke(Color.tpReferenceMint.opacity(0.7), lineWidth: 1)
                        }
                        .frame(width: layout.cell - 2, height: layout.cell - 2)
                        .offset(x: CGFloat(placement.x) * layout.cell, y: CGFloat(placement.y) * layout.cell)
                        .allowsHitTesting(false)
                }
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, cell in
                    Button {
                        placeLandFromMap(x: cell.x, y: cell.y)
                    } label: {
                        RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                            .strokeBorder(Color.tpAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                            .background(Color.tpAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous))
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: min(20, layout.cell * 0.32), weight: .bold))
                                    .foregroundStyle(Color.tpAccent)
                            }
                            .frame(width: layout.cell - 2, height: layout.cell - 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(cell.x) * layout.cell, y: CGFloat(cell.y) * layout.cell)
                    .accessibilityLabel(language.text("여기에 땅 이어 붙이기", "Attach land here"))
                }
            }
            .frame(width: 0, height: 0)
            .rotationEffect(.degrees(-layout.heading))
            .position(layout.center)
        }
    }

    private struct HomeLandLayout {
        let center: CGPoint
        let cell: CGFloat
        let heading: Double
    }

    /// 집 핀의 화면 위치와 한 칸의 화면 크기. 집이 없거나 너무 멀리 있거나 기울어져 있으면 nil.
    private func homeLandLayout(viewport: MapHomeVectorViewport?) -> HomeLandLayout? {
        guard let viewport,
              viewport.pitch < 5,
              mapViewportSize.height > 0,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return nil }
        let metersPerPoint = viewport.span.latitudeDelta * 111_320 / Double(mapViewportSize.height)
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return nil }
        let cell = CGFloat(Self.landCellMeters / metersPerPoint)
        // 너무 작게 보이면 그리지 않고, 화면보다 훨씬 크면 그리지 않는다.
        guard cell >= 14, cell <= 900 else { return nil }
        return HomeLandLayout(center: pin, cell: cell, heading: viewport.heading)
    }

    private func placeLandFromMap(x: Int, y: Int) {
        guard canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        guard let plotID = history.season.landPlots.first(where: { id in
            !(history.season.landPlotPlacements ?? []).contains { $0.plotID == id }
        }), MapHomeGrowthPolicy.placeLandPlot(plotID, atX: x, y: y, in: &history.season),
              let encoded = try? JSONEncoder().encode(history) else { return }
        homeGrowthData = encoded
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
        guard scenePhase == .active else { return }
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

    private func presentMapLongPressMenu(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        pendingLongPressCoordinate = coordinate
        isLongPressMenuPresented = true
    }

    private func presentLocationAddition(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        isSearchPinMenuPresented = true
    }

    private func routeLongPress(_ action: MapHomeLongPressAction) {
        guard let coordinate = pendingLongPressCoordinate else { return }
        pendingLongPressCoordinate = nil
        switch action {
        case .location:
            presentLocationAddition(at: coordinate)
        case .memo:
            addMapMemo(at: coordinate)
        }
    }

    private var homeGrowthHistory: MapHomeGrowthHistory {
        growthHistoryCache.history(for: homeGrowthData) ?? .initial(for: .now)
    }

    /// 저장된 값이 있는데 읽지 못하면 초기값으로 덮어쓰지 않는다.
    private var canWriteHomeGrowth: Bool {
        homeGrowthData.isEmpty || growthHistoryCache.history(for: homeGrowthData) != nil
    }

    private func refreshHomeGrowth(at now: Date) {
        guard model.isBootstrapped, scenePhase == .active, canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        let calendar = MapHomeGrowthPolicy.localCalendar
        if let key = history.season.pendingDay,
           let day = MapHomeGrowthPolicy.date(for: key, calendar: calendar),
           calendar.startOfDay(for: day) < calendar.startOfDay(for: now) {
            history.season.pendingDayQualified = MapHomeGrowthPolicy.qualifiesDay(
                actuals: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: day,
                asOf: now,
                calendar: calendar
            )
        }
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: now,
            calendar: calendar
        )
        if calendar.isDate(model.selectedDate, inSameDayAs: now),
           let dayData = currentDayDataSnapshot {
            MapHomeGrowthPolicy.observeCurrentDay(
                in: &history,
                date: now,
                qualified: MapHomeGrowthPolicy.qualifiesDay(
                    actuals: dayData.actuals,
                    travel: dayData.travel,
                    on: now,
                    asOf: now,
                    calendar: calendar
                ),
                calendar: calendar
            )
        }
        guard let encoded = try? JSONEncoder().encode(history),
              encoded != homeGrowthData else { return }
        homeGrowthData = encoded
    }

    private func rewardRecentCompletedDay(_ day: Date, asOf now: Date = .now) {
        guard canWriteHomeGrowth else { return }
        let calendar = MapHomeGrowthPolicy.localCalendar
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        var history = homeGrowthHistory
        if let key = history.season.pendingDay,
           let pendingDate = MapHomeGrowthPolicy.date(for: key, calendar: calendar),
           calendar.startOfDay(for: pendingDate) < calendar.startOfDay(for: now) {
            history.season.pendingDayQualified = MapHomeGrowthPolicy.qualifiesDay(
                actuals: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: pendingDate,
                asOf: now,
                calendar: calendar
            )
        }
        MapHomeGrowthPolicy.settleAndAwardRecentCompletion(
            in: &history,
            day: day,
            asOf: now,
            qualified: MapHomeGrowthPolicy.qualifiesDay(
                actuals: actuals,
                travel: travel,
                on: day,
                asOf: now,
                calendar: calendar
            ),
            calendar: calendar
        )
        guard let encoded = try? JSONEncoder().encode(history),
              encoded != homeGrowthData else { return }
        homeGrowthData = encoded
    }

    private var dayStepCount: Int? {
        currentDayReadings.compactMap(\.stepCount).filter { $0 > 0 }.max()
    }

    /// 하루를 대분류(수면·업무·이동·식사·취미·운동 등)로 묶은 요약. 세부 기록
    /// 원본(actuals)은 그대로 두고 파생 집계만 만든다. 비중은 관측된 총 시간
    /// 대비로 계산해 합이 100%가 되게 한다.
    private var daySummaryCategories: [MapHomeDaySummaryEntry] {
        let snap = currentDayDataSnapshot
        let actuals = snap?.actuals ?? []
        let travel = snap?.travel ?? []
        let stays = snap?.places ?? []
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: TimeSpan(start: start, end: end),
            asOf: .now
        )
        var totalsByID: [String: TimeInterval] = [:]
        for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) {
            guard entry.actual > 0 else { continue }
            totalsByID[entry.categoryID, default: 0] += entry.actual
        }
        // 식사는 대분류 phase에 없어 '활동'에 흡수된다. 활동 구간과 식사
        // 기록(원본 actuals)의 겹치는 시간만큼을 활동에서 떼어 '식사'로 옮긴다.
        // 총합·이동·수면 집계는 그대로 두고 세부 원본도 건드리지 않는다.
        let eatingSpans = actuals
            .filter { RecordAnalysisCategoryPolicy.categoryID(for: $0) == "eating" }
            .map { $0.span(asOf: .now) }
        if !eatingSpans.isEmpty {
            let activityPhaseSpans = phases
                .filter { RecordAnalysisCategoryPolicy.canonicalPhase($0.phase).rawValue == "activity" }
                .map(\.span)
            // 겹치는 식사 기록·인접 활동 phase가 같은 초를 두 번 세지 않도록,
            // 활동∩식사 교집합 구간을 모아 union으로 병합한 뒤 합산한다.
            var overlaps: [TimeSpan] = []
            for phaseSpan in activityPhaseSpans {
                for eating in eatingSpans {
                    if let overlap = phaseSpan.intersection(with: eating) {
                        overlaps.append(overlap)
                    }
                }
            }
            let eatingSeconds = Self.unionDuration(overlaps)
            let movedSeconds = min(eatingSeconds, totalsByID["activity"] ?? 0)
            if movedSeconds > 0 {
                totalsByID["activity", default: 0] -= movedSeconds
                totalsByID["eating", default: 0] += movedSeconds
                if (totalsByID["activity"] ?? 0) <= 0 {
                    totalsByID["activity"] = nil
                }
            }
        }
        let total = totalsByID.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return [] }
        return totalsByID
            .filter { $0.value > 0 }
            .map { id, seconds in
                let presentation = MapHomeSidebarMajorCategory.presentation(
                    for: id,
                    categoryColors: model.settings.mapCategoryColors
                )
                return MapHomeDaySummaryEntry(
                    id: id,
                    title: presentation.localizedTitle(language),
                    systemImage: presentation.systemImage,
                    tint: presentation.tint,
                    seconds: seconds,
                    ratio: seconds / total
                )
            }
            .sorted { $0.seconds > $1.seconds }
    }

    /// 겹치는 구간을 병합해 총 소요 시간을 반환한다(같은 초 중복 계산 방지).
    private static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    /// 하단 메뉴 고정: 홈 배치는 하단 탭으로 고정한다(선택 메뉴 제거).
    private var layoutStyle: MapHomeLayoutStyle { .tabBar }

    private func openMenu() {
        isLocationMenuExpanded = false
        isUserLocationsMenuExpanded = false
        isCategoryMenuExpanded = false
        isDisplayMenuExpanded = false
        isSettingsMenuExpanded = false
        isGPSLoggingMenuExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { isMenuOpen = true }
    }

    /// 하단 탭·떠 있는 독. 기존 버튼 동작을 그대로 호출하고 위치만 아래로 모은다.
    private var bottomActionBar: some View {
        let items = HStack(spacing: 0) {
            bottomBarButton("line.3.horizontal", language.text("메뉴", "Menu")) { openMenu() }
            Button {
                isCalendarPresented = true
            } label: {
                VStack(spacing: 4) {
                    MapHomeCalendarGlyph(date: model.selectedDate, language: language)
                        .frame(width: 26, height: 26)
                    Text(language.text("달력", "Calendar"))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("달력", "Calendar"))
            bottomBarButton("location.fill", language.text("현재 위치", "Location")) {
                requestAndFollowUserLocation(using: nil)
            }
            // 하단 가운데 집 버튼: 지도를 집으로 옮기고 땅 타일이 보이는 배율까지 확대한다(요약·성장 시트는 지도의 집 아이콘).
            bottomBarButton("house.fill", language.text("집", "Home")) {
                focusMapOnHome()
            }
            bottomBarButton(
                isDayPlaybackRunning ? "pause.fill" : "play.fill",
                isDayPlaybackRunning ? language.text("일시 정지", "Pause") : language.text("재생", "Play")
            ) {
                toggleDayPlayback()
            }
            bottomBarButton("record.circle", language.text("녹화", "Record"), tint: .tpHoliday) {
                openRecordingOptions()
            }
            bottomBarButton("plus", language.text("메모", "Memo"), tint: .tpReferenceBlue) {
                isMemoAddMenuPresented = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .padding(.bottom, 14)

        return items
            .background {
                // 하단 메뉴는 리퀴드 글래스: 지도가 비치면서도 아이콘과 글자가 읽힌다.
                Color.clear
                    .mapHomeGlass(in: Rectangle())
                    .ignoresSafeArea(edges: .bottom)
            }
    }

    private func bottomBarButton(
        _ systemImage: String,
        _ title: String,
        tint: Color = .tpInk,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 오른쪽 위 날짜 배지: 요일(토 파랑, 일·공휴일 빨강)과 큰 날짜. 누르면 달력을 연다.
    private var dateBadge: some View {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        let weekday = calendar.component(.weekday, from: model.selectedDate)
        let isHoliday = MapHomeCalendarDayStyle(date: model.selectedDate, calendar: calendar) == .holiday
        let color: Color = isHoliday || weekday == 1 ? .tpHoliday : (weekday == 7 ? .tpReferenceBlue : .tpInk)
        let weekdayText = model.selectedDate.formatted(
            Date.FormatStyle()
                .weekday(.abbreviated)
                .locale(Locale(identifier: language.text("ko_KR", "en_US")))
        )
        let badge = VStack(spacing: 0) {
            Text(weekdayText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(String(calendar.component(.day, from: model.selectedDate)))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .monospacedDigit()
        }
        .frame(width: Layout.timeRailWidth, height: Layout.dateBadgeSize)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 더블탭은 오늘 날짜로 이동해 경로를 화면에 맞추고, 한 번 탭하면 선택일이 속한 주를 왼쪽으로 펼친다.
        .onTapGesture(count: 2) {
            isDateWeekExpanded = false
            jumpToTodayAndCurrentMapPosition()
            // 날짜를 바꾸면 경로 데이터가 늦게 들어오므로, 불러온 뒤 한 번 더 전체 경로를 화면에 맞춘다.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !isDayPlaybackRunning else { return }
                focusMapOnAllRoutes()
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isDateWeekExpanded.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveDate(by: 1)
            case .decrement: moveDate(by: -1)
            @unknown default: break
            }
        }
        .accessibilityLabel(language.text("날짜 \(dateTitle)", "Date \(dateTitle)"))
        .accessibilityHint(language.text("한 번 누르면 이번 주, 두 번 누르면 오늘로 이동", "Tap for the week, double-tap for today"))
        return HStack(spacing: 6) {
            if isDateWeekExpanded { weekStrip(calendar: calendar) }
            badge
        }
    }

    private func weekStrip(calendar: Calendar) -> some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: model.selectedDate)?.start ?? model.selectedDate
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        return HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let weekday = calendar.component(.weekday, from: day)
                let isHoliday = MapHomeCalendarDayStyle(date: day, calendar: calendar) == .holiday
                let tint: Color = isHoliday || weekday == 1 ? .tpHoliday : (weekday == 7 ? .tpReferenceBlue : .tpInk)
                let isSelected = calendar.isDate(day, inSameDayAs: model.selectedDate)
                Button {
                    shouldFitRoutesAfterDateChange = true
                    model.selectedDate = day
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isDateWeekExpanded = false }
                } label: {
                    VStack(spacing: 0) {
                        Text(day.formatted(Date.FormatStyle().weekday(.narrow).locale(Locale(identifier: language.text("ko_KR", "en_US")))))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                        Text(String(calendar.component(.day, from: day)))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tpInk)
                            .monospacedDigit()
                    }
                    .frame(width: 34, height: Layout.dateBadgeSize)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.tpReferenceBlue.opacity(0.22))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 3) {


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



            if !layoutStyle.movesActionsToBottom {
                Button {
                    openRecordingOptions()
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: Layout.headerHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("재생 화면 녹화", "Record playback"))
            }

        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .fixedSize(horizontal: true, vertical: false)
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
                        isSearchExpanded = true
                        mapSearchCompleter.update(
                            query: mapSearchText,
                            region: mapSearchRegion
                        )
                    } else if mapSearchText.isEmpty
                        && mapSearchResults.isEmpty
                        && selectedSearchPin == nil {
                        isSearchExpanded = false
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
            .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
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
                .background(Color.tpSurface.opacity(0.96), in: Circle())
                .overlay {
                    Circle().stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
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
        case .mapLibreRPG: language.text("판타지 지도", "Fantasy Map")
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
        case .mapLibreRPG: "map.circle.fill"
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
        isSearchExpanded = false
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
        isSearchExpanded = false
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
        isSearchExpanded = false
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

    private func loadPhotoMoments() async {
        guard showsPhotosOnMap else {
            photoMoments = []
            return
        }
        var state = photoLibrary.permissionState()
        if state == .notDetermined { state = await photoLibrary.requestAccess() }
        guard state == .authorized || state == .limited else {
            photoMoments = []
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let library = photoLibrary
        let readings = currentDayReadings
        let moments = await Task.detached(priority: .utility) {
            MapHomePhotoPolicy.placingUnlocated(
                library.moments(in: TimeSpan(start: dayStart, end: dayEnd)),
                readings: readings
            )
        }.value
        guard !Task.isCancelled else { return }
        // 위치를 끝내 못 구한 사진이 있으면 하루 데이터가 들어온 뒤 한 번 더 맞춘다.
        photosNeedReadingRetry = moments.contains { $0.location == nil }
        photoMoments = MapHomePhotoPolicy.locatedMoments(moments)
    }

    private var photoClusters: [MapHomePhotoCluster] {
        guard showsPhotosOnMap, !photoMoments.isEmpty, recordingShows(\.photos) else { return [] }
        let radius = MapHomePhotoPolicy.clusterRadiusMeters(cameraDistance: visibleMapCamera?.distance)
        return photoClusterCache.clusters(for: photoMoments, radiusMeters: radius)
    }

    /// 핀에 보일 대표 사진·개수·강조 여부. 재생 중에는 지나온 사진만 순서대로 나타난다.
    private func photoPinInfo(for cluster: MapHomePhotoCluster) -> (coverID: String, count: Int, highlighted: Bool)? {
        if isDayPlaybackRunning {
            let minute = dayPlaybackCurrentMinute ?? Double(effectiveTimelineMinute)
            let visible = MapHomePhotoPolicy.playbackVisibleMoments(in: cluster, playbackMinute: minute)
            guard let cover = visible.last else { return nil }
            return (cover.id, visible.count, true)
        }
        let highlighted = selectedTimelineMinute != nil
            && MapHomePhotoPolicy.isHighlighted(cluster, selectedMinute: Double(effectiveTimelineMinute))
        let cover = highlighted
            ? cluster.moments.min {
                abs(MapHomePhotoPolicy.minuteOfDay($0.capturedAt) - Double(effectiveTimelineMinute))
                    < abs(MapHomePhotoPolicy.minuteOfDay($1.capturedAt) - Double(effectiveTimelineMinute))
            } ?? cluster.moments[0]
            : cluster.moments[0]
        return (cover.id, cluster.count, highlighted)
    }

    private func vectorPhotoMarkerID(_ id: String) -> String { "photo-\(id)" }

    private var recordingLayers: MapHomeRecordingLayers {
        MapHomeRecordingLayers(rawValue: recordingLayersRaw)
    }

    /// 녹화 중에는 고른 레이어만 보이고, 녹화 중이 아니면 항상 보인다.
    private func recordingShows(_ layer: KeyPath<MapHomeRecordingLayers, Bool>) -> Bool {
        !isScreenRecording || recordingLayers[keyPath: layer]
    }

    /// 달력 지표 합계. 사진 수는 비싸고 천천히 바뀌어 `includePhotos`가 true일 때만 읽는다.
    private func calendarTimeTotals(month: Date, includePhotos: Bool) async -> [Date: [String: TimeInterval]] {
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        let stays = model.snapshot.places
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        var result = await Task.detached(priority: .utility) {
            MapHomeCalendarTimeTotalsPolicy.totals(
                actuals: actuals,
                travel: travel,
                stays: stays,
                placeKinds: placeKinds,
                month: month,
                asOf: .now,
                calendar: MapHomeGrowthPolicy.localCalendar
            )
        }.value
        // 걸음 수·사진 수는 사용자가 "+"로 켠 때만 읽는다(건강·사진 접근 비용을 아끼기 위해).
        let enabled = MapHomeCalendarTimeKind.enabledExtras(
            from: UserDefaults.standard.string(forKey: MapHomeCalendarTimeKind.extraStorageKey) ?? ""
        )
        if enabled.contains(.steps) || enabled.contains(.stepDistance) {
            let stride = MapHomeStride.current
            for (day, steps) in await model.calendarDailyStepCounts(month: month) {
                if enabled.contains(.steps) { result[day, default: [:]][MapHomeCalendarTimeKind.steps.rawValue] = steps }
                if enabled.contains(.stepDistance), steps > 0 {
                    result[day, default: [:]][MapHomeCalendarTimeKind.stepDistance.rawValue] = steps * stride
                }
            }
        }
        if includePhotos, enabled.contains(.photos) {
            let library = photoLibrary
            let counts = await Task.detached(priority: .utility) {
                MapHomeCalendarTimeTotalsPolicy.photoCounts(in: month, moments: library.moments(in:), calendar: MapHomeGrowthPolicy.localCalendar)
            }.value
            for (day, count) in counts {
                result[day, default: [:]][MapHomeCalendarTimeKind.photos.rawValue] = count
            }
        }
        return result
    }

    /// 녹화 메뉴를 열기 전에 사진 저장 권한과 화면 기록 허용을 먼저 받는다.
    private func openRecordingOptions() {
        Task { @MainActor in
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            guard await screenRecorder.probePermission() else {
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            isRecordingOptionsPresented = true
        }
    }

    private func startRecordingPlayback() {
        isRecordingOptionsPresented = false
        // 권한 확인·ReplayKit 시작 대기 동안 기존 재생이 계속 돌지 않게 먼저 멈춘다.
        if isDayPlaybackRunning { stopDayPlayback(resetProgress: true) }
        Task { @MainActor in
            // 권한은 재생 전에 먼저 묻는다: 사진 저장 → 화면 녹화.
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                TaptionPlanDiagnosticsLogger.shared.record("screen_recording_blocked", fields: ["reason": "photo_access_denied"])
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            isScreenRecording = true
            // 시트가 내려가고 화면이 정리될 시간을 둔다.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard await screenRecorder.start() else {
                isScreenRecording = false
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            // 녹화는 항상 자정(0시)부터 처음부터 재생한다.
            startDayPlayback(fromMidnight: true)
        }
    }

    private func finishRecordingPlayback() {
        guard isScreenRecording else { return }
        Task { @MainActor in
            let url = await screenRecorder.stop()
            isScreenRecording = false
            guard let url else { return }
            let saved = await MapHomeScreenRecordingStore.saveToPhotos(url)
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_saved", fields: ["saved": saved ? "true" : "false"])
            recordedVideoURL = url
            isRecordedVideoSharePresented = true
        }
    }

    private func toggleDayPlayback() {
        if isDayPlaybackRunning {
            stopDayPlayback(resetProgress: false)
        } else {
            startDayPlayback()
        }
    }

    private func startDayPlayback(fromMidnight: Bool = false) {
        dayPlaybackTask?.cancel()
        let currentDate = Date.now
        let playbackEndMinute = MapHomeDayPlaybackMath.playbackEndMinute(
            for: model.selectedDate,
            now: currentDate
        )
        let defaultMinute = MapHomeDayPlaybackMath.playbackStartMinute(
            selectedMinute: selectedTimelineMinute,
            endMinute: playbackEndMinute,
            isToday: Calendar.autoupdatingCurrent.isDate(
                model.selectedDate,
                inSameDayAs: currentDate
            )
        )
        let pawSelection = MapHomePawprintInteractionPolicy.selection(
            timestamp: selectedPawprintTimestamp, isPredicted: false,
            selectedDate: model.selectedDate
        )
        let currentMinute = fromMidnight ? 0 : (pawSelection.map {
            defaultMinute == Double($0.minute) && $0.minuteOffset < playbackEndMinute
                ? $0.minuteOffset : defaultMinute
        } ?? defaultMinute)
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        var playbackMinute = currentMinute
        dayPlaybackCurrentMinute = currentMinute
        let movingRanges = dayPlaybackMovementRanges
        let zoomDayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let zoomReadings = routeReadings + model.liveRouteState.readings
        let zoomPlaces = model.settings.frequentPlaces.compactMap(\.point)
        playbackZoomPlan = MapHomePlaybackZoomPlan(
            inputs: MapHomePlaybackZoomInputBuilder.inputs(
                ranges: movingRanges,
                dayStart: zoomDayStart,
                travel: currentDayDataSnapshot?.travel ?? [],
                readings: zoomReadings,
                places: zoomPlaces
            ),
            profile: MapHomePlaybackZoomProfile.build(
                readings: zoomReadings,
                places: zoomPlaces,
                dayStart: zoomDayStart
            )
        )
        if currentMinute == 0 {
            selectedTimelineMinute = 0
        }
        isTimelineSelectionPinned = true
        isTimelineInteractionActive = true
        isDayPlaybackRunning = true
        playbackZoomSmoother.reset()
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
        recordCurrentPlaybackAlignment()
        lastPlaybackRouteProjectionUptime = ProcessInfo.processInfo.systemUptime
        startPlaybackIntro()
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
                    dayPlaybackCurrentMinute = nil
                    _ = flushDeferredRouteProjection()
                        ?? refreshRouteProjection()
                    flushDeferredWBSPlaybackProjection()
                    recordCurrentPlaybackAlignment()
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
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let readingRanges = dayPlaybackReadingRanges(
            from: routeReadings + model.liveRouteState.readings,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        let travelRanges = (dayData?.travel ?? []).compactMap {
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
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.timestamp >= dayStart
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

    /// 재생 시작 연출: 전체 경로를 먼저 보여 주고, 시작 지점으로 줌인한 뒤 재생 카메라에 넘긴다.
    private func startPlaybackIntro() {
        playbackIntroTask?.cancel()
        guard let region = mapRouteFitRegion else { return }
        isPlaybackIntroActive = true
        setMapPosition(.region(region))
        playbackIntroTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, isDayPlaybackRunning,
                  let point = displayedPlaybackFocusPoint else {
                isPlaybackIntroActive = false
                return
            }
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    distance: MapHomePlaybackZoomPolicy.baselineDistance,
                    heading: 0,
                    pitch: 0
                )
            ))
            try? await Task.sleep(for: .seconds(1.4))
            isPlaybackIntroActive = false
        }
    }

    private func stopDayPlayback(resetProgress: Bool) {
        playbackIntroTask?.cancel()
        isPlaybackIntroActive = false
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
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
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        lastTimelineMapFocusUptime = 0
        if wasRunning {
            isTimelineInteractionActive = false
            _ = flushDeferredRouteProjection()
                ?? refreshRouteProjection()
            flushDeferredWBSPlaybackProjection()
            recordCurrentPlaybackAlignment()
        }
    }

    @ViewBuilder
    private var mapSideRails: some View {
        if !isMenuOpen {
            GeometryReader { proxy in
                mapSideRailsContent(viewportSize: proxy.size)
            }
            .zIndex(MapHomeLayerPriority.sidebar)
        }
    }

    private func mapSideRailsContent(viewportSize: CGSize) -> some View {
        let frame = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: viewportSize.height,
            topInset: topOverlayHeight + Layout.timeRailTopMargin,
            bottomInset: Layout.horizontalInset + layoutStyle.bottomReservedHeight
        )
        let timeSidebarFrame = MapHomeOverlayLayoutMath.timeSidebarFrame(
            viewportHeight: viewportSize.height,
            topOverlayHeight: 0,
            topMargin: Layout.horizontalInset * 2 + Layout.dateBadgeSize,
            bottomMargin: Layout.horizontalInset + layoutStyle.bottomReservedHeight
        )
        let timeSidebarWidth = MapHomeTimeSidebarMath.interactionWidth(
            railWidth: Layout.timeRailWidth,
            trailingInteractionWidth: Layout.horizontalInset
        )
        return HStack(alignment: .top, spacing: 0) {
            if !isScreenRecording {
            mapControls(proxy: nil, railHeight: frame.height)
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
            Spacer(minLength: 0)
            Color.clear
                .frame(width: timeSidebarWidth, height: frame.height)
        }
        .padding(.leading, Layout.horizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: frame.height)
        .overlay(alignment: .topTrailing) {
            currentTimeRail
                .frame(width: timeSidebarWidth, height: timeSidebarFrame.height)
                .offset(y: timeSidebarFrame.minY - frame.minY)
        }
        .position(x: viewportSize.width / 2, y: frame.midY)
    }

    private var currentTimeRail: some View {
        GeometryReader { proxy in
            let railHeight = MapHomeOverlayLayoutMath.timeSidebarHeight(
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
                let selectedTimeCard = MapHomeTimeSidebarMath.selectedTimeCardFrame(
                    availableHeight: railHeight,
                    selectedMinute: minute,
                    visibleStartMinute: timeSidebarVisibleStartMinute,
                    visibleDurationMinutes: timeSidebarVisibleDurationMinutes
                )
                let selectedCardHeight = min(railHeight, selectedTimeCard.height)
                let selectedCardCenterY = min(
                    max(selectedTimeCard.midY, selectedCardHeight / 2),
                    railHeight - selectedCardHeight / 2
                )
                let timeRailTop = max(0, proxy.size.height - railHeight)
                ZStack(alignment: .topLeading) {
                    if recordingShows(\.timeSidebar) {
                    Capsule()
                        .fill(Color.tpAccent.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.tpAccent.opacity(0.20), lineWidth: 0.8)
                        }
                        .frame(
                            width: Layout.timeRailWidth - 12,
                            height: selectedCardHeight
                        )
                        .position(
                            x: proxy.size.width
                                - Layout.horizontalInset
                                - (Layout.timeRailWidth - 12) / 2,
                            y: timeRailTop + selectedCardCenterY
                        )
                        .allowsHitTesting(false)
                    }
                    if model.settings.weatherSidebarVisible, recordingShows(\.weatherSidebar) {
                        let railWeather = MapHomeWeatherDisplayCache.contexts(
                            incoming: model.snapshot.weather,
                            cached: cachedWeatherContexts
                        )
                        if let notice = MapHomeWeatherNoticePolicy.notice(
                            status: model.weatherStatus,
                            hasDisplayableWeather: railWeather.contains {
                                MapHomeWeatherDisplayPolicy.isComplete($0)
                                    && Calendar.autoupdatingCurrent.isDate(
                                        $0.observedAt,
                                        inSameDayAs: model.selectedDate
                                    )
                            }
                        ) {
                            MapHomeWeatherNoticeView(notice: notice, language: language)
                                .frame(width: MapHomeWeatherNoticeView.width, alignment: .trailing)
                                .offset(
                                    x: weatherOriginX + Layout.weatherRailWidth
                                        - MapHomeWeatherNoticeView.width,
                                    y: 6
                                )
                                .allowsHitTesting(false)
                        }
                        MapHomeWeatherSidebar(
                            date: model.selectedDate,
                            contexts: railWeather,
                            selectedMinute: minute,
                            language: language,
                            visibleStartMinute: weatherVisibleStartMinute,
                            visibleDurationMinutes: weatherVisibleDurationMinutes
                        )
                        .offset(x: weatherOriginX)
                        .allowsHitTesting(false)
                    }
                    if recordingShows(\.timeSidebar) {
                    MapHomeTimeSidebar(
                        date: model.selectedDate,
                        selectedMinute: Binding(
                            get: { timelineSelectionMinute(at: timeline.date) },
                            set: { minute in
                                selectedPawprintTimestamp = nil
                                guard selectedTimelineMinute != minute else { return }
                                stopDayPlayback(resetProgress: true)
                                isTimelineSelectionPinned = true
                                selectedTimelineMinute = minute
                            }
                        ),
                        activity: model.isBootstrapped
                            ? currentActivity(at: minute)
                            : nil,
                        segments: timeRailSegments,
                        categoryColors: model.settings.mapCategoryColors,
                        zoomResetToken: zoomResetToken,
                        railWidth: Layout.timeRailWidth,
                        maximumSelectableMinute: nil,
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
                            guard model.isBootstrapped else { return }
                            openSectionEditor(at: selectedMinute)
                        },
                        onUnconfirmedReview: { segment in
                            guard model.isBootstrapped else { return }
                            focusedUnconfirmedReviewSegment = segment
                            isUnconfirmedReviewPresented = true
                        }
                    )
                    }

                    ForEach(recordingShows(\.sidebarMemos) ? scheduleStickersForSelectedDate : []) { sticker in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: sticker.occurredAt)
                        let trackHeight = max(
                            1,
                            railHeight - MapHomeTimeSidebarMath.verticalInset * 2
                        )
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(
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
                            y: min(
                                max(y, MapHomeTimeSidebarMath.verticalInset),
                                railHeight - MapHomeTimeSidebarMath.verticalInset
                            )
                        )
                    }
                }
                .onChange(of: timeline.date) { _, date in
                    refreshHomeGrowth(at: date)
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

    private func mapControls(
        proxy: MapProxy?,
        railHeight: CGFloat
    ) -> some View {
        let locationState = MapHomeLocationButtonState.resolve(
            hasLocation: displayedLocationCoordinate != nil,
            trackingMode: userTrackingMode,
            isCentered: isMapCenteredOnUser
        )
        let locationStateLabel: String
        switch locationState {
        case .unavailable:
            locationStateLabel = language.text("위치 없음", "Unavailable")
        case .locating:
            locationStateLabel = language.text("위치 찾는 중", "Locating")
        case .available:
            locationStateLabel = language.text("위치 사용 가능", "Available")
        case .following:
            locationStateLabel = language.text("현재 위치 따라가기", "Following")
        }
        return VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)

            if isLeftControlsExpanded {
                VStack(spacing: 2) {
                    // 접힌 검색: 돋보기 버튼을 좌하단에 두고, 누르면 상단 입력창이 펼쳐진다.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchExpanded = true
                        }
                        // 창이 마운트된 다음 런루프에 포커스를 줘야 @FocusState가 무시되지 않는다.
                        DispatchQueue.main.async {
                            isMapSearchFocused = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpInk)
                            .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    }
                    .accessibilityLabel(language.text("장소 검색", "Search places"))

                    if !layoutStyle.movesActionsToBottom {
                        Button {
                            requestAndFollowUserLocation(using: proxy)
                        } label: {
                            MapHomeLocationButtonIcon(
                                state: locationState,
                                showsGPSDot: hasConfirmedCurrentGPS
                            )
                            .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        }
                        .accessibilityLabel(language.text("현재 위치", "Current location"))
                        .accessibilityValue(locationStateLabel)
                    }

                    if isHeadingMode {
                        Button {
                            toggleMapHeadingMode(using: proxy)
                        } label: {
                            Image("MapHomeCompass")
                                .resizable()
                                .scaledToFit()
                                .padding(9)
                                .rotationEffect(.degrees(compassRotationDegrees))
                                .animation(.linear(duration: 0.12), value: compassRotationDegrees)
                                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
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
                        }
                        .accessibilityLabel(language.text("나침반 표시", "Show compass"))
                    }

                    VStack(spacing: 0) {
                        mapZoomButton(systemImage: "plus", direction: 1, proxy: proxy)
                        if let scale = MapHomeCameraZoomMath.scale(distance: visibleMapCamera?.distance) {
                            Button {
                                fitMapToRoutes()
                            } label: {
                                Text("\(scale)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.tpSecondary)
                                    .frame(width: Layout.mapControlSize, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language.text("지도 배율 \(scale)", "Map zoom \(scale)"))
                            .accessibilityHint(language.text("이동 경로에 맞춰 화면 배율을 조정합니다", "Fits the map to the route"))
                        }
                        mapZoomButton(systemImage: "minus", direction: -1, proxy: proxy)
                    }

                    VStack(spacing: 0) {
                        Button {
                            model.undoLastUserEdit()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                                .foregroundStyle(model.canUndo ? Color.tpInk : Color.tpSecondary.opacity(0.48))
                                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        }
                        .accessibilityLabel(language.text("실행취소", "Undo"))
                        .disabled(!model.canUndo)

                        Button {
                            model.redoLastUserEdit()
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                                .foregroundStyle(model.canRedo ? Color.tpInk : Color.tpSecondary.opacity(0.48))
                                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        }
                        .accessibilityLabel(language.text("다시실행", "Redo"))
                        .disabled(!model.canRedo)
                    }

                    if !layoutStyle.movesActionsToBottom {
                        Button {
                            isMemoAddMenuPresented = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                                .foregroundStyle(Color.tpReferenceBlue)
                                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        }
                        .accessibilityLabel(language.text("메모 추가", "Add memo"))
                    }

                    Button {
                        isLeftControlsExpanded = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                            .frame(width: Layout.mapControlSize, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("컨트롤 접기", "Collapse controls"))
                }
                .padding(.vertical, 4)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                Button {
                    isLeftControlsExpanded = true
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        .mapHomeGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("컨트롤 펼치기", "Expand controls"))
            }
        }
        .frame(width: Layout.timeRailWidth, height: railHeight)
        .shadow(color: .black.opacity(0.045), radius: 5, y: 1)
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
        recordUserMapAdjustment()
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
                .background(Color.tpSurface.opacity(0.62))
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.6), lineWidth: 0.8)
                }
                .padding(.top, menuTop)
                // 왼쪽 가장자리에서 펼쳐져 오른쪽 시간 사이드바를 가리지 않는다.
                .padding(.leading, Layout.horizontalInset)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
            }
        }
    }

    private var sidebarContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("MapHomeHomeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 53)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("오늘의 기록", "Today's Record"))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(language.text("자동으로 남은 하루의 기록", "Today's activity, automatically recorded"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isMenuOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .mapHomeGlass(in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)

            if !sensorCollectionPermissionGate.sensorCollectionReady {
                sensorPermissionCard
                    .padding(.bottom, 10)
            }

            menuGroupLabel(language.text("기록", "Record"))
            menuGroupCard {
                locationMenuItem
                menuGroupDivider
                categoryMenuItem
            }
            menuGroupLabel(language.text("화면", "View"))
            menuGroupCard {
                displayMenuItem
                menuGroupDivider
                languageMenuItem
            }
            menuGroupLabel(language.text("연결", "Connections"))
            menuGroupCard {
                appleWatchMenuItem
            }
            menuGroupLabel(language.text("앱", "App"))
            menuGroupCard {
                settingsMenuItem
                menuGroupDivider
                Button {
                    isMapAttributionPresented = true
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.tpAccent)
                            .frame(width: 32, height: 32)
                            .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(language.text("지도 출처", "Map attribution"))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.tpInk)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 28)

            if TaptionCommercePolicy.supportsPaidPurchase {
                menuItem(
                    "sparkles",
                    proMenuTitle,
                    isSelected: proAccess.hasPermanentAccess
                ) {
                    proAccess.isPurchaseSheetPresented = true
                }
            }

            Divider()
                .padding(.vertical, 9)

            HStack(spacing: 8) {
                Circle()
                    .fill(currentCoordinate == nil ? Color.tpInk.opacity(0.3) : Color.tpAccent)
                    .frame(width: 7, height: 7)
                Text(
                    currentCoordinate == nil
                        ? language.text("위치 기록을 기다리는 중", "Waiting for location")
                        : language.text("현재 위치 기록 중", "Recording current location")
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mapHomeGlass(in: Capsule())

            Divider()
                .padding(.vertical, 9)

            appVersionFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MapHomeScrollBounceDisabler())
    }

    /// 메인 메뉴 묶음 제목과 카드. 항목은 카드 안에서 얇은 구분선으로 나눈다.
    private func menuGroupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .padding(.horizontal, 6)
    }

    private func menuGroupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .background(Color.tpSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.8)
        }
    }

    private var menuGroupDivider: some View {
        Divider()
            .overlay(Color.tpLine.opacity(0.7))
            .padding(.leading, 57)
            .padding(.trailing, 12)
    }

    private var appVersionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return Text(
            language.text(
                "BOKKI Plan \(version) (빌드 \(build))",
                "BOKKI Plan \(version) (Build \(build))"
            )
        )
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var categoryMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isCategoryMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(language.text("행동 분류", "Activity categories"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isCategoryMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(language.text("위치", "Location"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isLocationMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .foregroundStyle(Color.tpInk)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
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
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isDisplayMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(language.text("표시", "Display"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isDisplayMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)

            if isDisplayMenuExpanded {
                Button {
                    isStrideCalibrationPresented = true
                } label: {
                    Label(language.text("보폭 보정(걸음 → 거리)", "Stride calibration"), systemImage: "shoeprints.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpAccent)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                .buttonStyle(.plain)
                Text(language.text("지도 스타일", "Map style"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 12)

                Picker(
                    selection: Binding(
                        get: { model.settings.mapDisplayStyle },
                        set: { model.setMapDisplayStyle($0) }
                    )
                ) {
                    ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                        Label(
                            mapStyleTitle(style),
                            systemImage: mapStyleSystemImage(style)
                        )
                        .tag(style)
                    }
                } label: {
                    Label(
                        language.text("지도 스타일", "Map style"),
                        systemImage: "map.fill"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .pickerStyle(.menu)
                .tint(Color.tpAccent)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .accessibilityLabel(
                    language.text("지도 스타일 선택", "Choose map style")
                )

                Toggle(isOn: $autoLandStyleEnabled) {
                    Label(
                        language.text("땅 보기 자동 전환", "Auto-switch for land"),
                        systemImage: "square.grid.3x3.square"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .tint(Color.tpReferenceBlue)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

                Picker(
                    selection: Binding(
                        get: { MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) ?? .adaptive },
                        set: { playbackZoomModeRaw = $0.rawValue }
                    )
                ) {
                    ForEach(MapHomePlaybackZoomMode.allCases, id: \.self) { mode in
                        Text(language.text(mode.koreanTitle, mode.englishTitle)).tag(mode)
                    }
                } label: {
                    Label(
                        language.text("재생 배율", "Playback zoom"),
                        systemImage: "plus.magnifyingglass"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .pickerStyle(.menu)
                .tint(Color.tpAccent)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)


                Toggle(isOn: $fogOfWarEnabled) {
                    Label(
                        language.text("안개 탐험", "Fog of Exploration"),
                        systemImage: "cloud.fog.fill"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .tint(Color.tpAccent)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

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

                Toggle(isOn: $showsPhotosOnMap) {
                    Label(
                        language.text("사진", "Photos"),
                        systemImage: "photo.fill"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .tint(Color.tpReferenceBlue)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

                Picker(
                    selection: Binding(
                        get: { memoDisplayMode },
                        set: { memoDisplayRaw = $0.rawValue }
                    )
                ) {
                    ForEach(MapHomeMemoDisplayMode.allCases, id: \.self) { mode in
                        Text(language.text(mode.koreanTitle, mode.englishTitle)).tag(mode)
                    }
                } label: {
                    Label(
                        language.text("메모", "Memos"),
                        systemImage: "note.text"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .pickerStyle(.menu)
                .tint(Color.tpAccent)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

                Picker(
                    selection: Binding(
                        get: { model.settings.mapMemoDisplayFilter },
                        set: { model.setMapMemoDisplayFilter($0) }
                    )
                ) {
                    ForEach(MapMemoDisplayFilter.allCases, id: \.self) { filter in
                        Text(mapMemoDisplayFilterTitle(filter))
                            .tag(filter)
                    }
                } label: {
                    Label(
                        language.text("지도 메모", "Map memos"),
                        systemImage: "note.text"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .pickerStyle(.menu)
                .tint(Color.tpReferenceBlue)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .accessibilityLabel(
                    language.text("지도 메모 표시 방식", "Map memo display mode")
                )
            }
        }
    }

    private func mapMemoDisplayFilterTitle(
        _ filter: MapMemoDisplayFilter
    ) -> String {
        switch filter {
        case .all:
            language.text("모든 지도 메모", "All map memos")
        case .relevant:
            language.text("일정 관련 메모", "Schedule-related memos")
        }
    }

    private var settingsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { isSettingsMenuExpanded.toggle() } label: {
                HStack(spacing: 13) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(language.text("설정", "Settings"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isSettingsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Color.tpInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("설정 목록", "Settings list"))

            if isSettingsMenuExpanded {
                Button { isDataProtectionPresented = true } label: {
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
                    .background(Color.tpReferenceRose.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("데이터 보호 열기", "Open data protection"))
                .padding(.leading, 12)

                Button { isSettingsResetConfirmationPresented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("설정 초기화", "Reset settings"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(language.text("화면·연동 설정을 기본값으로 복원", "Restore display and integration settings"))
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
                    .background(Color.tpReferenceRose.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("설정 초기화", "Reset settings"))
                .padding(.leading, 12)

                gpsLoggingMenuItem.padding(.leading, 12)
            }
        }
    }

    private var appleWatchMenuItem: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.refreshAppleWatchConnectionState()
                isAppleWatchMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Apple Watch 데이터", "Apple Watch data"))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(appleWatchDataStatusText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isAppleWatchMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Color.tpInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            if isAppleWatchMenuExpanded {
                Button(language.text("지금 가져오기", "Import now")) {
                    if model.settings.healthEnabled {
                        model.requestWatchDataSync(source: "map_watch_card")
                    } else {
                        Task { await model.requestHealth() }
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.tpAccent)
            }
        }
    }

    /// "사용 가능 · 10월 19일 오후 4:51 가져옴" / "사용 불가"
    private var appleWatchDataStatusText: String {
        let available: Bool
        switch model.appleWatchConnectionState {
        case .unsupported, .notPaired: available = false
        case .appNotInstalled, .noRecentData, .background, .reachable: available = model.settings.healthEnabled
        }
        guard available else { return language.text("사용 불가", "Unavailable") }
        guard let fetched = model.lastHealthRefreshAt else {
            return language.text("사용 가능", "Available")
        }
        let stamp = fetched.formatted(.dateTime.month().day().hour().minute())
        return language.text("사용 가능 · \(stamp) 가져옴", "Available · fetched \(stamp)")
    }

    private var dataProtectionStatusText: String {
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

    private var sensorCollectionPermissionGate: RequiredPermissionGate {
        model.requiredPermissionGate(liveActivitiesEnabled: false)
    }

    private var sensorPermissionCard: some View {
        let missing = sensorCollectionPermissionGate.sensorCollectionMissing
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                language.text("자동 기록 권한", "Automatic recording permissions"),
                systemImage: "sensor.fill"
            )
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.tpAccent)

            Text(
                language.text(
                    "수동 기록과 지도 메모는 지금 사용할 수 있습니다. 자동 기록을 켜려면 필요한 권한만 허용하세요.",
                    "Manual records and map memos are available now. Allow only the permissions needed for automatic recording."
                )
            )
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(missing, id: \.rawValue) { permission in
                Button {
                    guard requestingPermission == nil else { return }
                    requestingPermission = permission
                    Task { @MainActor in
                        await model.requestRequiredPermission(permission)
                        requestingPermission = nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sensorPermissionIcon(permission))
                            .frame(width: 20)
                        Text(sensorPermissionTitle(permission))
                        Spacer(minLength: 4)
                        if requestingPermission == permission {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(sensorPermissionActionTitle(permission))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 36)
                    .background(
                        Color.tpSurface.opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    requestingPermission != nil
                        || model.isRefreshingIntegrations
                )
                .accessibilityLabel(
                    language.text(
                        "\(sensorPermissionTitle(permission)) 권한 요청",
                        "Request \(sensorPermissionTitle(permission)) permission"
                    )
                )
            }
        }
        .padding(12)
        .background(
            Color.tpInk.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func sensorPermissionIcon(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationAlways, .locationPrecise:
            "location.fill"
        case .motion:
            "figure.walk.motion"
        case .healthKitRequestCompleted, .calendar, .notifications, .liveActivities:
            "checkmark"
        }
    }

    private func sensorPermissionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationAlways:
            language.text("위치 항상 허용", "Always Location")
        case .locationPrecise:
            language.text("정확한 위치", "Precise Location")
        case .motion:
            language.text("동작 및 피트니스", "Motion & Fitness")
        case .healthKitRequestCompleted, .calendar, .notifications, .liveActivities:
            ""
        }
    }

    private func sensorPermissionActionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationPrecise:
            language.text("설정 열기", "Open Settings")
        default:
            language.text("허용하기", "Allow")
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
                        // 1분 단위(1~15분), 5분 눈금 근처는 모델이 스냅한다.
                        Slider(
                            value: Binding(
                                get: { Double(preferences.intervalSeconds / 60) },
                                set: { minutes in
                                    let seconds = Int(minutes.rounded()) * 60
                                    let snapped = GPSLoggingPreferences.clampedSeconds(seconds)
                                    guard snapped != preferences.intervalSeconds else { return }
                                    model.setGPSLoggingIntervalSeconds(snapped)
                                }
                            ),
                            in: 1...15,
                            step: 1
                        )
                        .tint(tint)
                        .disabled(preferences.isBatteryMinimal)
                        HStack {
                            Text(gpsLoggingIntervalText(60))
                            Spacer()
                            Text(gpsLoggingIntervalText(300))
                            Spacer()
                            Text(gpsLoggingIntervalText(600))
                            Spacer()
                            Text(gpsLoggingIntervalText(900))
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
        guard sensorCollectionPermissionGate.sensorCollectionReady else {
            return language.text("권한 필요", "Permission needed")
        }
        return switch model.sensorCollectionSessionState {
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
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.tpAccent : Color.tpInk.opacity(0.55))
                    .frame(width: 26, alignment: .center)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.tpAccent : Color.tpInk)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tpInk.opacity(0.28))
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 13)
            .background(
                isSelected ? Color.tpAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var placeAnnotations: [MapHomePlaceAnnotation] {
        let homeWeather = MapHomeHomeWeatherBadgePolicy.badge(
            from: model.snapshot.weather,
            now: .now
        )
        return model.settings.frequentPlaces.compactMap { place in
            guard let destination = MapHomeLocationDestination(placeKind: place.kind),
                  let point = place.point,
                  isValid(point) else { return nil }
            return MapHomePlaceAnnotation(
                id: place.id,
                name: displayedFrequentPlaceName(place),
                floor: place.floor,
                destination: destination,
                growthLevel: destination == .home
                    ? homeGrowthHistory.season.level
                    : nil,
                isLeapDay: MapHomeGrowthPolicy.isLeapDay(
                    model.selectedDate,
                    calendar: MapHomeGrowthPolicy.localCalendar
                ),
                growthStatus: destination == .home
                    ? homeGrowthMarkerStatus
                    : nil,
                isGrowthQualifiedToday: destination == .home
                    && isHomeGrowthQualifiedToday,
                growthStreak: destination == .home
                    ? homeGrowthHistory.season.streak
                    : 0,
                pendingWeeklyRewards: destination == .home
                    ? homeGrowthHistory.season.pendingWeeklyRewards
                    : 0,
                isCatAtHome: destination == .home && isDisplayedCatAtHome,
                catAction: displayedStickmanAction,
                equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                weatherBadge: destination == .home ? homeWeather : nil
            )
        }
    }

    private var isDisplayedCatAtHome: Bool {
        guard let current = displayedLocationCoordinate,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let point = home.point else { return false }
        return MapHomePresencePolicy.isAtHome(
            current: current,
            home: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            radiusMeters: home.radiusMeters
        )
    }

    private var homeGrowthMarkerStatus: String {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let history = homeGrowthHistory
        let today = Date.now
        guard calendar.isDate(model.selectedDate, inSameDayAs: today),
              history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar),
              history.season.pendingDayQualified else {
            return language.text("오늘 기록을 쌓아보세요", "Build today's log")
        }
        return language.text("오늘 성장 조건 충족", "Today's growth goal met")
    }

    private var isHomeGrowthQualifiedToday: Bool {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let today = Date.now
        let history = homeGrowthHistory
        return calendar.isDate(model.selectedDate, inSameDayAs: today)
            && history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar)
            && history.season.pendingDayQualified
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
        .filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
                && seen.insert($0.id).inserted
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private var transitBoardingCandidates: [TransitBoardingCandidate] {
        let dayData = currentDayDataSnapshot
        let registeredLocations = model.settings.userTransitLocations
        let nearbyPlaces = nearbyTransitPlaces
        let travel = dayData?.travel ?? []
        let decisions = model.settings.transitBoardingDecisions
        let cutoff = routeOverlayCutoff
        let key = MapHomeTransitBoardingCandidateCacheKey(
            dayProjectionRevision: model.dayProjectionRevision,
            settingsHash: {
                var hasher = Hasher()
                hasher.combine(registeredLocations)
                hasher.combine(decisions)
                return hasher.finalize()
            }(),
            readingsRevision: transitBoardingReadingsRevision,
            nearbyPlacesRevision: nearbyTransitPlacesRevision,
            cutoff: MapHomeTransitBoardingRefreshPolicy.cutoffBucket(cutoff)
        )
        return mapRenderCache.transitBoardingCandidates(key: key) {
            let readings = transitBoardingReadings
            let candidates = TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                decisions: decisions,
                through: cutoff
            )
            var fields = transitBoardingDiagnostics(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                through: cutoff
            )
            fields["candidate_count"] = String(candidates.count)
            fields["candidate_names"] = Array(
                Set(candidates.map(\.name))
            ).sorted().joined(separator: ";")
            fields["candidate_travel_segment_count"] = String(
                Set(candidates.flatMap(\.travelSegmentIDs)).count
            )
            fields["decision_count"] = String(decisions.count)
            TaptionPlanDiagnosticsLogger.shared.record(
                "transit_boarding_candidates_evaluated",
                fields: fields
            )
            return candidates
        }
    }

    private func refreshTransitBoardingCandidatesIfNeeded(at date: Date) -> Bool {
        guard scenePhase == .active else { return false }
        guard MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
            lastRefresh: lastTransitBoardingLiveRefreshAt,
            at: date
        ) else { return false }
        lastTransitBoardingLiveRefreshAt = date
        transitBoardingReadingsRevision &+= 1
        return true
    }

    private func transitBoardingDiagnostics(
        readings: [SensorReading],
        registeredLocations: [UserTransitLocation],
        nearbyPlaces: [TransitBoardingPlace],
        travel: [TravelSegment],
        through cutoff: Date
    ) -> [String: String] {
        let withPoint = readings.filter { $0.point != nil }
        let gpsAvailable = readings.filter(\.gpsAvailable)
        let precise = readings.filter {
            $0.locationFixQuality != .approximate
        }
        let usable = readings.filter { reading in
            guard reading.gpsAvailable,
                  reading.locationFixQuality != .approximate,
                  let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude) else {
                return false
            }
            return point.horizontalAccuracy <= 0
                || point.horizontalAccuracy <= 200
        }
        let poweredModes: Set<TravelMode> = [
            .bus, .subway, .taxi, .car, .train, .airplane, .ship,
        ]
        let poweredTravel = travel.filter {
            poweredModes.contains($0.mode)
        }
        let stationNames = Array(Set(
            (registeredLocations.map(\.name)
                + nearbyPlaces.map(\.name)
                + readings.compactMap(\.nearbyStationName))
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
        )).sorted().joined(separator: ";")
        return [
            "cutoff": String(cutoff.timeIntervalSince1970),
            "readings": String(readings.count),
            "readings_with_point": String(withPoint.count),
            "readings_gps_available": String(gpsAvailable.count),
            "readings_precise": String(precise.count),
            "readings_usable": String(usable.count),
            "registered_transit_places": String(registeredLocations.count),
            "nearby_transit_places": String(nearbyPlaces.count),
            "transit_place_names": stationNames,
            "travel_segments": String(travel.count),
            "travel_powered_segments": String(poweredTravel.count),
            "travel_unconfirmed_powered_segments": String(
                poweredTravel.filter { !$0.isConfirmed }.count
            ),
            "travel_mode_counts": transitModeCounts(travel.map(\.mode)),
            "reading_station_name_count": String(
                Set(readings.compactMap(\.nearbyStationName)).count
            ),
            "reading_rail_match_count": String(
                readings.filter(\.matchesRailRoute).count
            ),
            "reading_transit_match_count": String(
                readings.filter(\.matchesPublicTransitRoute).count
            ),
        ]
    }

    private func transitModeCounts(_ modes: [TravelMode]) -> String {
        let counts = Dictionary(grouping: modes, by: { $0 })
        return TravelMode.allCases.compactMap { mode in
            guard let count = counts[mode]?.count else { return nil }
            return "\(mode.rawValue)=\(count)"
        }.joined(separator: ",")
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let readings = currentMapLocationReading.map { [$0] } ?? []
        let temporaryLocations = SubwayStationCatalog.temporaryLocations(from: readings)
        let point = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
        )?.point ?? RealtimeSensorMapProjection.project(
            readings: readings,
            at: .now,
            temporaryLocations: temporaryLocations
        )?.point
        guard let point, isValid(point) else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    /// GPS를 아직 못 받았을 때 화랑이가 있을 가장 최근 위치(최신 센서 → 실시간 경로 → 오늘 경로 마지막 점).
    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        let candidates: [() -> GeoPoint?] = [
            { model.latestSensorReading?.point },
            { model.liveRouteState.readings.last?.point },
            { displayRouteReadings.last(where: { $0.point != nil })?.point },
            { currentDayReadings.last(where: { $0.point != nil })?.point },
        ]
        // 앞 후보로 정해지면 하루치 병합·정렬(currentDayReadings)은 계산하지 않는다.
        for candidate in candidates {
            if let point = candidate(), isValid(point) {
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        }
        return nil
    }

    /// 위치 버튼·따라가기가 맞출 좌표: 확정 현재 위치, 없으면 가장 최근 위치.
    private var liveFocusCoordinate: CLLocationCoordinate2D? {
        currentCoordinate ?? lastKnownCoordinate
    }

    private var hasConfirmedCurrentGPS: Bool {
        MapHomeCurrentGPSPolicy.isConfirmed(
            in: currentMapLocationReading.map { [$0] } ?? []
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
        guard scenePhase == .active else { return }
        guard model.isBootstrapped else {
            if !timeRailSegments.isEmpty {
                timeRailSegments = []
            }
            return
        }
        let dayData = currentDayDataSnapshot
        let next = MapHomeTimeRailSegmentEngine.segments(
            from: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            on: model.selectedDate
        )
        if next != timeRailSegments {
            timeRailSegments = next
        }
    }

    private func resetDayScopedMapState(for date: Date) {
        routeReadingsPreparationTask?.cancel()
        routeReadingsPreparationTask = nil
        routeReadingsPreparationGeneration.advance()
        dayDataSnapshot = nil
        routeActualIndex = nil
        routeReadings = []
        normalizedRouteReadings = []
        currentMapLocationReading = nil
        historicalPlaybackReadings = []
        displayRouteReadings = []
        lastPreparedRouteReadingsSignature = nil
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        routeProjection = nil
        wbsPlaybackProjection = nil
        timelineRouteOverlays = []
        cachedTemporaryLocations = []
        expectedRouteOverlays = []
        wbsGeneratedRouteOverlays = []
        pendingForecastRouteState = nil
        expectedRouteCache.removeAll(keepingCapacity: true)
        expectedRouteRefreshTask?.cancel()
        expectedRouteRefreshTask = nil
        expectedRouteRefreshGeneration &+= 1
        wbsExpectedRouteRequests = []
        wbsExpectedRouteRequestsInputKey = nil
        liveRouteProjectionRefreshTask?.cancel()
        liveRouteProjectionRefreshTask = nil
        nearbyTransitPlaces = []
        hasDeferredWBSPlaybackRefresh = false
        timeRailSegments = []
        timeSidebarVisibleStartMinute = 0
        timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
        zoomResetToken += 1
        hasAppliedInitialMapFocus = false
        routeDocumentProjectionGate.reset()
        mapRenderCache.invalidateRouteData()
    }

    private var currentDayDataSnapshot: PlanDayDataSnapshot? {
        guard let dayDataSnapshot,
              dayDataSnapshot.sourceRevision == model.dayProjectionRevision
                || (!model.isBootstrapped && dayDataIsPreview && model.hasPreparedStartupSettings),
              dayDataSnapshot.projectionVersion == TaptionPlanV3Store.projectionVersion,
              Calendar.autoupdatingCurrent.isDate(
                  dayDataSnapshot.day,
                  inSameDayAs: model.selectedDate
              ) else { return nil }
        return dayDataSnapshot
    }

    private var isDayDataLoading: Bool {
        guard case let .loading(day) = routeReadingsLoadState else {
            return false
        }
        return Calendar.autoupdatingCurrent.isDate(
            day,
            inSameDayAs: model.selectedDate
        )
    }

    private var currentDayReadings: [SensorReading] {
        guard let dayData = currentDayDataSnapshot else {
            return historicalPlaybackReadings
        }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return MapHomeRouteReadingsPolicy.merging(
            existing: dayData.readings,
            loaded: model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? []),
            in: TimeSpan(start: start, end: end)
        )
    }

    private func refreshSelectedTimelineMapPosition(
        minute: Int?,
        using proxy: MapProxy? = nil
    ) {
        let deferredProjection = flushDeferredRouteProjection()
        guard minute != nil else { return }
        _ = deferredProjection
            ?? refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        guard let point = displayedPlaybackFocusPoint else { return }
        focusMap(on: point, using: proxy, followsTracking: true)
    }

    private func openSectionEditor(at minute: Int) {
        guard model.isBootstrapped else { return }
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
        }.filter { visible in
            !hasRouteDecision(predictedRoute(for: expectedRouteOverlays.first { $0.id == visible.id } ?? visible))
        }
    }

    private var displayedExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        Array(
            visibleExpectedRouteOverlays.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
    }

    private var visibleWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        let cutoff = routeOverlayCutoff
        return wbsGeneratedRouteOverlays.filter { !hasRouteDecision(predictedRoute(for: $0)) }.compactMap {
            $0.visible(through: cutoff)
        }
    }

    private var displayedWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        let remaining = max(
            0,
            MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                - displayedExpectedRouteOverlays.count
        )
        return Array(visibleWBSGeneratedRouteOverlays.prefix(remaining))
    }

    private func scheduleExpectedRouteRefresh() {
        expectedRouteRefreshGeneration &+= 1
        let refreshGeneration = expectedRouteRefreshGeneration
        if pendingForecastRouteState != nil {
            pendingForecastRouteState = nil
        }
        expectedRouteRefreshTask?.cancel()
        guard scenePhase == .active else {
            expectedRouteRefreshTask = nil
            return
        }
        expectedRouteRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            await refreshExpectedRouteOverlays(generation: refreshGeneration)
            guard !Task.isCancelled,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            expectedRouteRefreshTask = nil
        }
    }

    private func currentExpectedRouteInputKey() -> MapHomeExpectedRouteInputKey {
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: selectedDay)
            ?? selectedDay.addingTimeInterval(24 * 60 * 60)
        let dayData = currentDayDataSnapshot
        let liveReadings = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        return MapHomeExpectedRouteInputKey(
            selectedDay: selectedDay,
            dayEnd: dayEnd,
            dayProjectionRevision: model.dayProjectionRevision,
            daySourceRevision: dayData?.sourceRevision,
            daySourceUpdatedAt: dayData?.sourceUpdatedAt,
            daySourceFingerprint: dayData?.sourceFingerprint,
            isPreview: dayDataIsPreview,
            readingsPreparationID: routeReadingsPreparationGeneration.currentID,
            normalizedReadings: MapHomeDayCacheReadingsFingerprint(
                readings: normalizedRouteReadings
            ),
            normalizedLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    normalizedRouteReadings.last
                ),
            liveReadings: MapHomeDayCacheReadingsFingerprint(
                readings: liveReadings
            ),
            liveLastUpdatedAt: model.liveRouteState.lastUpdatedAt,
            liveLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    liveReadings.last
                ),
            latestRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    latestReading
                )
        )
    }

    private func isCurrentExpectedRouteRefresh(
        generation: UInt64,
        inputKey: MapHomeExpectedRouteInputKey
    ) -> Bool {
        !Task.isCancelled
            && scenePhase == .active
            && generation == expectedRouteRefreshGeneration
            && inputKey == currentExpectedRouteInputKey()
    }

    private func refreshExpectedRouteOverlays(generation: UInt64) async {
        guard scenePhase == .active, !Task.isCancelled,
              generation == expectedRouteRefreshGeneration else { return }
        let inputKey = currentExpectedRouteInputKey()
        let selectedDay = inputKey.selectedDay
        let dayEnd = inputKey.dayEnd
        let dayData = currentDayDataSnapshot
        let travel = dayData?.travel ?? []
        let placesCount = (dayData?.places ?? []).count
        let normalizedReadings = normalizedRouteReadings
        let playbackReadings = currentDayReadings
        let day = TimeSpan(start: selectedDay, end: dayEnd)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var overlayOperationCount = 0
            let overlayRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: normalizedReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                operationCount: &overlayOperationCount
            )
            try Task.checkCancellation()
            var playbackOperationCount = 0
            let playbackRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: playbackReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                operationCount: &playbackOperationCount
            )
            try Task.checkCancellation()
            return MapHomeExpectedRouteRequestBatch(
                overlayRequests: overlayRequests,
                playbackRequests: playbackRequests,
                overlayOperationCount: overlayOperationCount,
                playbackOperationCount: playbackOperationCount,
                readingsWithPointCount: normalizedReadings.reduce(into: 0) {
                    if $1.point != nil { $0 += 1 }
                },
                unconfirmedTravelCount: travel.reduce(into: 0) {
                    if !$1.isConfirmed { $0 += 1 }
                }
            )
        }
        let batch: MapHomeExpectedRouteRequestBatch
        do {
            batch = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
        } catch {
            worker.cancel()
            return
        }
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        if wbsExpectedRouteRequests != batch.playbackRequests {
            wbsExpectedRouteRequests = batch.playbackRequests
        }
        if wbsExpectedRouteRequestsInputKey != inputKey {
            wbsExpectedRouteRequestsInputKey = inputKey
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_requests_built",
            fields: expectedRouteRequestDiagnostics(
                requests: batch.overlayRequests,
                travelCount: travel.count,
                unconfirmedTravelCount: batch.unconfirmedTravelCount,
                placesCount: placesCount,
                readingsCount: normalizedReadings.count,
                readingsWithPointCount: batch.readingsWithPointCount,
                dayStart: selectedDay,
                dayEnd: dayEnd,
                operationCount: batch.overlayOperationCount,
                playbackOperationCount: batch.playbackOperationCount
            )
        )
        if expectedRouteCache.count > 128 {
            expectedRouteCache.removeAll(keepingCapacity: true)
        }

        let limitedRequests = Array(
            batch.overlayRequests.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
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
            generated: [],
            expectedRouteRequests: batch.playbackRequests
        )
        let excludedLegIDs = Set(
            fallbackExpected.map { "movement-\($0.id.uuidString)" }
                + storedWBSResolvedRoutes.map(\.legID)
        )
        let fallbackGenerated = Array(
            generatedWBSRouteOverlays(
                from: fallbackProjection,
                excluding: excludedLegIDs
            ).prefix(
                max(
                    0,
                    MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                        - fallbackExpected.count
                )
            )
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "fallback",
            projection: fallbackProjection,
            expected: fallbackExpected,
            generated: fallbackGenerated,
            excludedLegIDs: excludedLegIDs
        )
        _ = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: fallbackExpected,
                generated: fallbackGenerated,
                refreshGeneration: generation,
                inputKey: inputKey
            )
        )

        var resolvedExpected: [MapHomeExpectedRouteOverlay] = []
        for request in limitedRequests {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            let coordinates: [CLLocationCoordinate2D]
            if let cached = expectedRouteCache[request], cached.count >= 2 {
                coordinates = cached
            } else {
                let resolved = await mapKitRouteCoordinates(for: request)
                guard isCurrentExpectedRouteRefresh(
                    generation: generation,
                    inputKey: inputKey
                ) else { return }
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
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }

        let resolvedProjection = makeWBSPlaybackProjection(
            expected: resolvedExpected,
            generated: [],
            expectedRouteRequests: batch.playbackRequests
        )
        var resolvedGenerated = Array(
            generatedWBSRouteOverlays(
                from: resolvedProjection,
                excluding: Set(
                    resolvedExpected.map { "movement-\($0.id.uuidString)" }
                        + storedWBSResolvedRoutes.map(\.legID)
                )
            ).prefix(
                max(
                    0,
                    MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                        - resolvedExpected.count
                )
            )
        )
        let resolvedExcludedLegIDs = Set(
            resolvedExpected.map { "movement-\($0.id.uuidString)" }
                + storedWBSResolvedRoutes.map(\.legID)
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_before_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        var networkResolvedCount = 0
        for index in resolvedGenerated.indices {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            guard let transport = wbsRouteTransport(for: resolvedGenerated[index].mode),
                  let start = resolvedGenerated[index].coordinates.first,
                  let end = resolvedGenerated[index].coordinates.last else { continue }
            let coordinates = await MapHomeAppleRouteResolver.shared.resolve(
                start: start,
                end: end,
                transport: transport,
                departureDate: resolvedGenerated[index].departureDate
            )
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            if let coordinates, coordinates.count >= 2 {
                resolvedGenerated[index] = MapHomeWBSGeneratedRouteOverlay(
                    id: resolvedGenerated[index].id,
                    mode: resolvedGenerated[index].mode,
                    departureDate: resolvedGenerated[index].departureDate,
                    arrivalDate: resolvedGenerated[index].arrivalDate,
                    coordinates: coordinates
                )
                networkResolvedCount += 1
            }
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_network_resolution",
            fields: [
                "generated_requested": String(resolvedGenerated.count),
                "generated_network_resolved": String(networkResolvedCount),
                "generated_network_fallback": String(
                    resolvedGenerated.count - networkResolvedCount
                ),
            ]
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_after_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        let didApply = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: resolvedExpected,
                generated: resolvedGenerated,
                refreshGeneration: generation,
                inputKey: inputKey
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
            id: request.id,
            segmentID: request.segmentID,
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

    private func expectedRouteRequestDiagnostics(
        requests: [ExpectedRouteRequest],
        travelCount: Int,
        unconfirmedTravelCount: Int,
        placesCount: Int,
        readingsCount: Int,
        readingsWithPointCount: Int,
        dayStart: Date,
        dayEnd: Date,
        operationCount: Int,
        playbackOperationCount: Int
    ) -> [String: String] {
        let requestModes = Dictionary(grouping: requests, by: \.mode)
        let requestSegmentIDs = Set(requests.map(\.segmentID))
        return [
            "day_start": String(dayStart.timeIntervalSince1970),
            "day_end": String(dayEnd.timeIntervalSince1970),
            "travel_segments": String(travelCount),
            "unconfirmed_travel_segments": String(unconfirmedTravelCount),
            "places": String(placesCount),
            "readings": String(readingsCount),
            "readings_with_point": String(readingsWithPointCount),
            "request_count": String(requests.count),
            "request_unique_segment_count": String(requestSegmentIDs.count),
            "request_duplicate_segment_count": String(
                max(0, requests.count - requestSegmentIDs.count)
            ),
            "request_mode_counts": TravelMode.allCases.compactMap { mode in
                guard let count = requestModes[mode]?.count else { return nil }
                return "\(mode.rawValue)=\(count)"
            }.joined(separator: ","),
            "route_cache_count": String(expectedRouteCache.count),
            "request_operations": String(operationCount),
            "playback_request_operations": String(playbackOperationCount),
        ]
    }

    private func recordExpectedRouteProjectionDiagnostics(
        phase: String,
        projection: MapHomeWBSPlaybackProjection,
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        excludedLegIDs: Set<String>
    ) {
        let forecastMovements = projection.legs.filter {
            $0.routePhase == .forecast && $0.activity == .movement
        }
        let forecastGapMovements = forecastMovements.filter {
            $0.id.hasPrefix("movement-gap-")
        }
        let forecastTravelMovements = forecastMovements.filter {
            !$0.id.hasPrefix("movement-gap-")
                && $0.id.hasPrefix("movement-")
        }
        let actualMovements = projection.legs.filter {
            $0.routePhase == .actual && $0.activity == .movement
        }
        var intervalOverlapPairs = 0
        var sameEndpointPairs = 0
        if forecastMovements.count > 1 {
            for index in 0..<(forecastMovements.count - 1) {
                for otherIndex in (index + 1)..<forecastMovements.count {
                    let lhs = forecastMovements[index]
                    let rhs = forecastMovements[otherIndex]
                    let lhsSpan = TimeSpan(
                        start: lhs.startDate,
                        end: lhs.endDate
                    )
                    if lhsSpan.intersection(with: TimeSpan(
                        start: rhs.startDate,
                        end: rhs.endDate
                    )) != nil {
                        intervalOverlapPairs += 1
                    }
                    guard let lhsStart = lhs.coordinates.first,
                          let lhsEnd = lhs.coordinates.last,
                          let rhsStart = rhs.coordinates.first,
                          let rhsEnd = rhs.coordinates.last else {
                        continue
                    }
                    let sameDirection = distanceMeters(lhsStart, rhsStart) <= 100
                        && distanceMeters(lhsEnd, rhsEnd) <= 100
                    let reverseDirection = distanceMeters(lhsStart, rhsEnd) <= 100
                        && distanceMeters(lhsEnd, rhsStart) <= 100
                    if sameDirection || reverseDirection {
                        sameEndpointPairs += 1
                    }
                }
            }
        }
        let generatedModes = Dictionary(
            grouping: generated.compactMap(\.mode),
            by: { $0 }
        )
        var routeCandidates: [MapHomeExpectedRouteDiagnostics.Candidate] = []
        for route in expected {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "expected", mode: route.mode.rawValue,
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for route in generated {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "generated", mode: route.mode?.rawValue ?? "unknown",
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for leg in forecastMovements {
            guard let first = leg.coordinates.first, let last = leg.coordinates.last else { continue }
            let kind: String = leg.id.hasPrefix("movement-gap-") ? "forecast_gap" : "forecast_movement"
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: kind, mode: "leg",
                start: leg.startDate, end: leg.endDate,
                first: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                last: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            ))
        }
        let routeSummary: [String: String] = MapHomeExpectedRouteDiagnostics.fields(for: routeCandidates)
        let baseFields: [String: String] = [
                "phase": phase,
                "expected_overlay_count": String(expected.count),
                "generated_overlay_count": String(generated.count),
                "projection_leg_count": String(projection.legs.count),
                "projection_forecast_movement_count": String(
                    forecastMovements.count
                ),
                "projection_forecast_travel_movement_count": String(
                    forecastTravelMovements.count
                ),
                "projection_forecast_gap_count": String(
                    forecastGapMovements.count
                ),
                "projection_actual_movement_count": String(
                    actualMovements.count
                ),
                "forecast_interval_overlap_pairs": String(
                    intervalOverlapPairs
                ),
                "forecast_same_endpoint_pairs": String(sameEndpointPairs),
                "excluded_leg_count": String(excludedLegIDs.count),
                "generated_mode_counts": TravelMode.allCases.compactMap {
                    mode in
                    guard let count = generatedModes[mode]?.count else {
                        return nil
                    }
                    return "\(mode.rawValue)=\(count)"
                }.joined(separator: ","),
        ]
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_projection_built",
            fields: baseFields.merging(routeSummary, uniquingKeysWith: { base, _ in base })
        )
    }

    private func wbsRouteTransport(
        for mode: TravelMode?
    ) -> ExpectedRouteTransport? {
        guard let mode else { return nil }
        switch mode {
        case .car, .taxi: return .automobile
        case .bus, .subway, .train: return .transit
        case .walking, .running, .cycling: return .walking
        case .airplane, .ship: return .direct
        }
    }

    @discardableResult
    private func applyForecastRouteState(
        _ state: MapHomeForecastRouteState
    ) -> Bool {
        guard state.refreshGeneration == expectedRouteRefreshGeneration,
              state.inputKey == currentExpectedRouteInputKey() else {
            return false
        }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            pendingForecastRouteState = state
            hasDeferredWBSPlaybackRefresh = true
            TaptionPlanDiagnosticsLogger.shared.record(
                "expected_route_state_deferred",
                fields: [
                    "expected_overlay_count": String(state.expected.count),
                    "generated_overlay_count": String(state.generated.count),
                ]
            )
            return false
        }
        pendingForecastRouteState = nil
        mapRenderCache.invalidateExpectedRoutes()
        expectedRouteOverlays = state.expected
        wbsGeneratedRouteOverlays = state.generated
        refreshWBSPlaybackProjection()
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_state_applied",
            fields: [
                "expected_overlay_count": String(state.expected.count),
                "generated_overlay_count": String(state.generated.count),
            ]
        )
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
        let dayData = currentDayDataSnapshot
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
            minute: cutoffMinute,
            sourceRevision: dayData?.sourceRevision
        ) {
            MapHomeSubwayRouteOverlayEngine.overlays(
                travel: dayData?.travel ?? [],
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
                coordinates: coordinates,
                coordinateTimestamps: segment.coordinateTimestamps
            )
        }
    }

    private var wbsPlaybackFrame: MapHomeWBSPlaybackFrame? {
        guard selectedTimelineMinute != nil else { return nil }
        return wbsPlaybackProjection?.frame(
            at: displayedLocationDate,
            preferredForecastLegIDs: visibleForecastPlaybackLegIDs
        )
    }

    private var visibleForecastPlaybackLegIDs: Set<String> {
        Set(
            displayedExpectedRouteOverlays.map {
                "movement-\($0.id.uuidString)"
            } + displayedWBSGeneratedRouteOverlays.map(\.id)
        )
    }

    private var historicalPlaybackCoordinate: CLLocationCoordinate2D? {
        guard let point = displayedPlaybackLocation?.coordinate,
              isValid(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var activeExpectedRoute: MapHomeExpectedRouteOverlay? {
        let date = displayedLocationDate
        let visibleIDs = Set(displayedExpectedRouteOverlays.map(\.id))
        return expectedRouteOverlays
            .filter {
                visibleIDs.contains($0.id)
                    && $0.coordinates.count >= 2
                    && $0.departureDate <= date
                    && date <= $0.arrivalDate
            }
            .min { $0.departureDate < $1.departureDate }
    }

    private var expectedRoutePlaybackCoordinate: CLLocationCoordinate2D? {
        activeExpectedRoute?.coordinate(at: displayedLocationDate)
    }

    private var displayedPlaybackFocusPoint: GeoPoint? {
        displayedPlaybackLocation?.cameraCoordinate
    }

    private var displayedPlaybackLocation: MapHomePlaybackLocation? {
        guard selectedTimelineMinute != nil else { return nil }
        if let point = selectedPawprintPoint {
            return MapHomePlaybackLocation(coordinate: point)
        }
        let frame = wbsPlaybackFrame
        let expectedPoint = frame == nil ? expectedRoutePlaybackCoordinate.flatMap { coordinate in
            CLLocationCoordinate2DIsValid(coordinate) ? wbsGeoPoint(coordinate) : nil
        } : nil
        return MapHomePlaybackLocation.resolve(
            at: displayedLocationDate,
            frame: frame,
            normalizedReadings: routeReadingsLoadState.isLoaded(for: model.selectedDate)
                ? historicalPlaybackReadings : [],
            confirmedTravel: currentDayDataSnapshot?.travel ?? [],
            expectedCoordinate: expectedPoint
        )
    }

    private var displayedLocationCoordinate: CLLocationCoordinate2D? {
        if selectedTimelineMinute != nil {
            return historicalPlaybackCoordinate
        }
        guard Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) else {
            return nil
        }
        return liveFocusCoordinate
    }

    private var displayedPlaybackMinute: Double? {
        guard selectedTimelineMinute != nil else { return nil }
        if isDayPlaybackRunning {
            return dayPlaybackCurrentMinute
                ?? Double(selectedTimelineMinute ?? effectiveTimelineMinute)
        }
        if let selection = MapHomePawprintInteractionPolicy.selection(
            timestamp: selectedPawprintTimestamp, isPredicted: false,
            selectedDate: model.selectedDate
        ), selection.minute == selectedTimelineMinute {
            return selection.minuteOffset
        }
        return Double(selectedTimelineMinute ?? effectiveTimelineMinute)
    }

    private var selectedPawprintPoint: GeoPoint? {
        guard !isDayPlaybackRunning,
              let coordinate = selectedPawprintCoordinate,
              let selection = MapHomePawprintInteractionPolicy.selection(
                timestamp: selectedPawprintTimestamp, isPredicted: false,
                selectedDate: model.selectedDate
              ), selection.minute == selectedTimelineMinute else { return nil }
        return wbsGeoPoint(coordinate)
    }

    private var displayedPlaybackDate: Date? {
        displayedPlaybackMinute.map(timelineDate(forMinute:))
    }

    private var displayedLocationDate: Date {
        if let displayedPlaybackDate {
            return displayedPlaybackDate
        }
        let calendar = Calendar.autoupdatingCurrent
        return calendar.isDateInToday(model.selectedDate)
            ? MapHomeTransitBoardingRefreshPolicy.cutoffBucket(.now)
            : calendar.startOfDay(for: model.selectedDate)
    }

    /// 마커 고양이가 속도 구간을 표현할 수 있도록 현재 표시 지점의 속도를
    /// m/s로 추정한다. 재생 중이면 현재 leg의 이동 세그먼트 속도(거리/시간),
    /// 실시간이면 최신 센서 속도를 쓴다. 정지/미확정이면 nil.
    private var displayedSpeedMetersPerSecond: Double? {
        if selectedTimelineMinute != nil {
            return MapHomePlaybackSpeed.speed(
                at: displayedLocationDate,
                travel: currentDayDataSnapshot?.travel ?? [],
                readings: historicalPlaybackReadings
            )
        }
        return model.latestSensorReading?.speedMetersPerSecond
    }

    private var displayedStickmanAction: MapHomeStickmanAction {
        let actuals = currentDayDataSnapshot?.actuals ?? []
        let sleepSessions = model.sleepSessions
        if MapHomeStickmanActionResolver.hasAppleWatchConfirmedSleep(
            at: displayedLocationDate,
            actuals: actuals,
            sleepSessions: sleepSessions
        ) {
            return .sleeping
        }
        if let frame = wbsPlaybackFrame {
            switch frame.activity {
            case .movement:
                if let mode = frame.mode {
                    return MapHomeStickmanActionResolver.action(for: mode)
                }
                return .movement
            case .stay:
                if let categoryID = frame.categoryID {
                    return MapHomeStickmanActionResolver.action(
                        for: categoryID,
                        label: ""
                    )
                }
            }
        }
        if let activeExpectedRoute {
            return MapHomeStickmanActionResolver.action(for: activeExpectedRoute.mode)
        }
        return MapHomeStickmanActionResolver.action(
            at: displayedLocationDate,
            actuals: actuals,
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            frequentPlaces: model.settings.frequentPlaces,
            readings: (currentDayDataSnapshot?.readings ?? routeReadings)
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? []),
            sleepSessions: sleepSessions
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

    /// 과거 날짜 기본값 1440분은 다음 날 0시가 되므로 저장·일정 판정용 시각은 그날 23:59로 묶는다.
    private var timelineSelectionDate: Date {
        timelineDate(forMinute: Double(min(
            effectiveTimelineMinute,
            MapHomeTimeSidebarMath.fullDayMinutes - 1
        )))
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
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let segment = MapHomeTimeRailSegmentEngine.segment(
                at: minute,
                in: timeRailSegments
              )
        else { return [] }
        return MapHomeSectionDetailEngine.details(
            actuals: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
    }

    private func refreshRouteReadings(
        for date: Date,
        forceReload: Bool = false,
        preloadedDayData: PlanDayDataSnapshot? = nil,
        cachedMapDay: MapHomeDayCachePayload? = nil,
        isPreview: Bool = false
    ) async {
        let viewSignpostID = OSSignpostID(log: Self.dayViewSignpostLog)
        os_signpost(
            .begin,
            log: Self.dayViewSignpostLog,
            name: "day_view",
            signpostID: viewSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.dayViewSignpostLog,
                name: "day_view",
                signpostID: viewSignpostID
            )
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return }
        var dayData: PlanDayDataSnapshot
        var showsCachedPreview = isPreview
        if let preloadedDayData, !forceReload {
            dayData = preloadedDayData
        } else {
            dayData = await model.planDayDataSnapshot(
                for: date,
                forceReload: forceReload
            )
        }
        guard !Task.isCancelled,
              TaptionDataDeletionFence.allows(generation: dataGeneration),
              calendar.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if dayData.sourceRevision != model.dayProjectionRevision, model.isBootstrapped {
            guard let rebased = await model.rebasePlanDayDataSnapshot(
                from: dayData,
                for: date
            ) else { return }
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            dayData = rebased
        }
        if !isPreview, !dayData.isComplete {
            let previous = dayDataSnapshot?.isComplete == true
                ? dayDataSnapshot
                : await model.cachedPlanDayDataSnapshot(for: date)
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
            if let previous, previous.isComplete,
               calendar.isDate(previous.day, inSameDayAs: date) {
                if previous.sourceRevision != model.dayProjectionRevision {
                    guard let rebased = await model.rebasePlanDayDataSnapshot(from: previous, for: date),
                          !Task.isCancelled,
                          TaptionDataDeletionFence.allows(generation: dataGeneration),
                          calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
                    dayData = rebased
                } else {
                    dayData = previous
                }
                showsCachedPreview = true
                TaptionPlanDiagnosticsLogger.shared.record("map_incomplete_reload_kept_preview",
                    fields: ["readings": String(previous.readings.count)])
            }
        }
        var snapshotFields = TaptionPlanDiagnosticsTravelSummary.fields(
            for: dayData.travel
        )
        snapshotFields["day_start"] = String(dayStart.timeIntervalSince1970)
        snapshotFields["source_revision"] = String(dayData.sourceRevision)
        snapshotFields["projection_version"] = String(dayData.projectionVersion)
        snapshotFields["source_updated_at"] = String(
            dayData.sourceUpdatedAt.timeIntervalSince1970
        )
        snapshotFields["is_complete"] = String(dayData.isComplete)
        snapshotFields["is_preview"] = String(showsCachedPreview)
        snapshotFields["readings"] = String(dayData.readings.count)
        snapshotFields["readings_with_point"] = String(
            dayData.readings.filter { $0.point != nil }.count
        )
        snapshotFields["places"] = String(dayData.places.count)
        snapshotFields["travel"] = String(dayData.travel.count)
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_snapshot_loaded",
            fields: snapshotFields
        )
        dayDataSnapshot = dayData
        routeActualIndex = nil
        dayDataIsPreview = showsCachedPreview
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: routeReadings,
            loaded: dayData.readings,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        routeReadingsLoadState = isPreview ? .loading(dayStart) : dayData.isComplete
            ? .loaded(dayStart)
            : .failed(dayStart)
        if merged != routeReadings {
            routeReadings = merged
            transitBoardingReadingsRevision &+= 1
        }
        if showsCachedPreview {
            refreshTimeRailSegments()
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            focusMapIfNeeded()
            return
        }
        let restoredCachedRoutes = cachedMapDay.map {
            applyMapDayCacheRoutes($0, for: date, dayData: dayData)
        } ?? false
        refreshTimeRailSegments()
        scheduleTransitPOIRefresh()
        scheduleExpectedRouteRefresh()
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(preparingReadings: true)
            return
        }
        if restoredCachedRoutes,
           selectedTimelineMinute == nil,
           !isDayPlaybackRunning {
            focusMapIfNeeded()
            return
        }
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        if selectedTimelineMinute != nil {
            recordCurrentPlaybackAlignment()
            if let point = displayedPlaybackFocusPoint {
                focusMap(
                    on: point,
                    followsTracking: true
                )
            }
        } else {
            focusMapIfNeeded()
        }
        persistMapDayCache()
    }

    private func scheduleTransitPOIRefresh() {
        guard MapHomeTransitPOIRefreshPolicy.canStart(
            isBootstrapped: model.isBootstrapped,
            isSceneActive: scenePhase == .active
        ) else { return }
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: dataGeneration
        ) else { return }
        let selectedDate = model.selectedDate
        let readings = transitBoardingReadings
        transitPOIRefreshTask?.cancel()
        transitPOIRefreshGeneration &+= 1
        let generation = transitPOIRefreshGeneration
        transitPOIRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            let places = await AppleTransitBoardingPOIResolver.shared.resolving(
                readings: readings
            )
            guard !Task.isCancelled,
                  generation == transitPOIRefreshGeneration,
                  scenePhase == .active,
                  TaptionDataDeletionFence.allows(
                    generation: dataGeneration
                  ),
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

    private func loadMapDayCache(
        for date: Date
    ) async -> MapHomeDayCachePayload? {
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return nil
        }
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        guard let payload = MapHomeDayCacheMemory.payload(
            day: TaptionPlanDayKey(date: date),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        ), Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            && TaptionDataDeletionFence.allows(generation: generation)
        else { return nil }
        guard payload.centerLatitude.isFinite,
              payload.centerLongitude.isFinite,
              (-90...90).contains(payload.centerLatitude),
              (-180...180).contains(payload.centerLongitude),
              payload.latitudeDelta.isFinite,
              payload.longitudeDelta.isFinite else { return nil }
        return payload
    }

    private func applyMapDayCacheRoutes(
        _ payload: MapHomeDayCachePayload,
        for date: Date,
        dayData: PlanDayDataSnapshot
    ) -> Bool {
        // Route cache is only a display accelerator. Never publish it before
        // the current raw-backed day snapshot has been validated.
        guard dayData.isComplete,
              let sourceFingerprint = dayData.sourceFingerprint,
              payload.sourceFingerprint == sourceFingerprint,
              payload.readingsFingerprint
                == MapHomeDayCacheReadingsFingerprint(
                    readings: dayData.readings
                ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_day_cache_rejected",
                fields: ["reason": "day_content_mismatch"]
            )
            return false
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
            guard coordinates.count >= 2,
                  coordinates.count == overlay.coordinateTimestamps.count,
                  overlay.coordinateTimestamps.allSatisfy(RouteTimelineTimestamp.isValid)
            else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: overlay.id,
                categoryID: overlay.categoryID,
                opacity: overlay.opacity,
                speedMetersPerSecond: overlay.speedMetersPerSecond,
                coordinates: coordinates,
                coordinateTimestamps: overlay.coordinateTimestamps
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
                segmentID: overlay.segmentID,
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
                guard !overlay.estimated, coordinates.count >= 2 else {
                    return nil
                }
                return MapHomeSubwayRouteOverlay(
                    id: overlay.id,
                    coordinates: coordinates,
                    estimated: overlay.estimated,
                    travelID: overlay.travelID
                )
            }
            mapRenderCache.restoreSubwayRoutes(
                day: Calendar.autoupdatingCurrent.startOfDay(for: date),
                minute: subwayMinute,
                overlays: overlays
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_cache_restored",
            fields: [
                "day_start": String(
                    Calendar.autoupdatingCurrent.startOfDay(
                        for: date
                    ).timeIntervalSince1970
                ),
                "timeline_overlay_count": String(timelineRouteOverlays.count),
                "expected_overlay_count": String(expectedRouteOverlays.count),
                "temporary_location_count": String(cachedTemporaryLocations.count),
                "subway_overlay_count": String((payload.subway ?? []).count),
                "source_updated_at": payload.sourceUpdatedAt.map {
                    String($0.timeIntervalSince1970)
                } ?? "none",
            ]
        )
        return true
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

    private func persistMapDayCache() {
        guard let dayData = currentDayDataSnapshot,
              dayData.isComplete,
              visibleMapCenter.latitude.isFinite,
              visibleMapCenter.longitude.isFinite,
              visibleMapSpan.latitudeDelta.isFinite,
              visibleMapSpan.longitudeDelta.isFinite else { return }
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let subwayMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: routeOverlayCutoff
        ).minute ?? effectiveTimelineMinute
        let readingsFingerprint = MapHomeDayCacheReadingsFingerprint(
            readings: dayData.readings
        )
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        var signature = Hasher()
        signature.combine(generation)
        signature.combine(dayStart.timeIntervalSinceReferenceDate.bitPattern)
        signature.combine(dayData.sourceFingerprint)
        signature.combine(readingsFingerprint.count)
        signature.combine(readingsFingerprint.firstID)
        signature.combine(readingsFingerprint.lastID)
        signature.combine(
            readingsFingerprint.firstTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(
            readingsFingerprint.lastTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(visibleMapCenter.latitude.bitPattern)
        signature.combine(visibleMapCenter.longitude.bitPattern)
        signature.combine(visibleMapSpan.latitudeDelta.bitPattern)
        signature.combine(visibleMapSpan.longitudeDelta.bitPattern)
        signature.combine(styleKey)
        signature.combine(subwayMinute)
        for overlay in timelineRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.categoryID)
            signature.combine(overlay.opacity.bitPattern)
            signature.combine(overlay.speedMetersPerSecond?.bitPattern)
        }
        for overlay in expectedRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.mode.rawValue)
            signature.combine(
                overlay.departureDate.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(
                overlay.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
            )
        }
        for overlay in subwayRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.estimated)
        }
        for location in temporaryLocationAnnotations {
            signature.combine(location.id)
            signature.combine(
                location.timestamp.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(location.stationName)
            signature.combine(location.point.latitude.bitPattern)
            signature.combine(location.point.longitude.bitPattern)
            signature.combine(location.reason)
        }
        let writeSignature = signature.finalize()
        guard writeSignature != mapDayCacheWriteSignature else { return }
        mapDayCacheWriteSignature = writeSignature
        let cachedSubwayRoutes = subwayRouteOverlays
        let payload = MapHomeDayCachePayload(
            sourceUpdatedAt: dayData.sourceUpdatedAt,
            sourceRevision: dayData.sourceRevision,
            sourceFingerprint: dayData.sourceFingerprint,
            readingsFingerprint: readingsFingerprint,
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
                    },
                    coordinateTimestamps: overlay.coordinateTimestamps
                )
            },
            expected: expectedRouteOverlays.map { overlay in
                MapHomeCachedExpectedRouteOverlay(
                    id: overlay.id,
                    segmentID: overlay.segmentID,
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
                    },
                    travelID: overlay.travelID
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
        MapHomeDayCacheMemory.store(
            payload,
            day: TaptionPlanDayKey(date: model.selectedDate),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        )
    }

    private func reportInitialMapShellReadyIfNeeded(for date: Date) {
        guard !hasReportedInitialDataReady,
              model.isBootstrapped || model.hasPreparedStartupSettings,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        hasReportedInitialDataReady = true
        TaptionPlanDiagnosticsLogger.shared.record("map_initial_shell_ready")
        onInitialDataReady()
    }

    private var routeOverlayCutoff: Date {
        let timelineDate = routeTimelineDate
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning,
            interactiveProjectionCutoff: isTimelineInteractionActive
                && !isDayPlaybackRunning
                ? routeProjection?.cutoff
                : nil
        )
    }

    private func requestRouteProjectionRefresh(
        preparingReadings: Bool = false
    ) {
        guard scenePhase == .active else { return }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(
                preparingReadings: preparingReadings
            )
            return
        }
        if preparingReadings {
            prepareRouteProjectionReadings()
        }
        refreshRouteProjection()
        recordCurrentPlaybackAlignment()
    }

    private func scheduleLiveRouteProjectionRefresh() {
        liveRouteProjectionRefreshTask?.cancel()
        guard scenePhase == .active else {
            liveRouteProjectionRefreshTask = nil
            return
        }
        liveRouteProjectionRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, scenePhase == .active else { return }
            mapRenderCache.invalidateRouteData()
            requestRouteProjectionRefresh(preparingReadings: true)
            if let timestamp = [
                model.latestSensorReading?.timestamp,
                model.liveRouteState.readings.last?.timestamp,
            ].compactMap({ $0 }).max() {
                removeCompletedExpectedRoutes(at: timestamp)
            }
            liveRouteProjectionRefreshTask = nil
        }
    }

    private func removeCompletedExpectedRoutes(at timestamp: Date) {
        guard !expectedRouteOverlays.isEmpty else { return }
        let travel = currentDayDataSnapshot?.travel ?? []
        let travelByID = Dictionary(
            uniqueKeysWithValues: travel.map { ($0.id, $0) }
        )
        let readings = currentDayReadings
        let completed = Set<UUID>(expectedRouteOverlays.compactMap { overlay in
            guard overlay.departureDate <= timestamp,
                  let segment = travelByID[overlay.segmentID],
                  TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
                      for: segment,
                      readings: readings
                  ) else { return nil }
            return overlay.id
        })
        guard !completed.isEmpty else { return }
        expectedRouteOverlays.removeAll { completed.contains($0.id) }
        mapRenderCache.invalidateExpectedRoutes()
        refreshWBSPlaybackProjection()
        persistMapDayCache()
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
        recordCurrentPlaybackAlignment()
        return projection
    }

    @discardableResult
    private func refreshRouteProjection() -> RouteTimelineProjection? {
        guard scenePhase == .active,
              let dayData = currentDayDataSnapshot else { return routeProjection }
        let calendar = Calendar.autoupdatingCurrent
        let actuals = dayData.actuals
        let actualIndex = routeActualIndex ?? RouteTimelineDataEngine.actualIndex(
            selectedDate: model.selectedDate,
            actuals: actuals,
            calendar: calendar
        )
        if routeActualIndex == nil {
            routeActualIndex = actualIndex
        }
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
            actuals: actuals,
            actualIndex: actualIndex,
            travel: dayData.travel,
            readings: displayRouteReadings,
            readingsAreNormalized: true,
            filtersSparseRouteConnections: true,
            confirmedSleepSpans: model.settings.confirmedSleepSpans,
            sleepSessions: model.sleepSessions,
            calendar: calendar
        )
        let overlays = makeTimelineRouteOverlays(next)
        let droppedSubway = next.segments.filter { $0.confirmedSubwayTravelID != nil }.count
        let droppedShort = next.segments.filter {
            $0.confirmedSubwayTravelID == nil && $0.coordinates.count < 2
        }.count
        TaptionPlanDiagnosticsLogger.shared.record(
            "fmap_route_projection",
            fields: [
                "segment_count": String(next.segments.count),
                "overlay_count": String(overlays.count),
                "overlay_coordinate_total": String(overlays.reduce(0) { $0 + $1.coordinates.count }),
                "dropped_subway_confirmed": String(droppedSubway),
                "dropped_short": String(droppedShort),
                "playback_running": String(isDayPlaybackRunning),
                "selected_minute": selectedTimelineMinute.map(String.init) ?? "none",
            ]
        )
        guard routeProjection != next
            || timelineRouteOverlays.map(\.id) != overlays.map(\.id)
        else { return next }
        mapRenderCache.invalidateRouteData()
        routeProjection = next
        timelineRouteOverlays = overlays
        return next
    }

    private func prepareRouteProjectionReadings() {
        guard scenePhase == .active else { return }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let preparationSignature = [
            String(dayStart.timeIntervalSinceReferenceDate),
            String(model.dayProjectionRevision),
            String(transitBoardingReadingsRevision),
            String(routeReadings.count),
            routeReadings.last?.id.uuidString ?? "none",
            String(model.liveRouteState.readings.count),
            model.liveRouteState.readings.last?.id.uuidString ?? "none",
            model.liveRouteState.lastUpdatedAt.map {
                String($0.timeIntervalSinceReferenceDate)
            } ?? "none",
            model.latestSensorReading?.id.uuidString ?? "none",
            model.latestSensorReading.map {
                String($0.timestamp.timeIntervalSinceReferenceDate)
            } ?? "none",
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                model.latestSensorReading
            ),
        ].joined(separator: "|")
        guard preparationSignature != lastPreparedRouteReadingsSignature else {
            if routeReadingsPreparationTask == nil {
                requestWBSPlaybackProjectionRefresh()
            }
            return
        }
        lastPreparedRouteReadingsSignature = preparationSignature
        routeReadingsPreparationTask?.cancel()
        let preparationID = routeReadingsPreparationGeneration.advance()
        let routeReadingsSnapshot = routeReadings
        let liveReadingsSnapshot = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        routeReadingsPreparationTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                try MapHomeRouteReadingsPreparation.prepare(
                    routeReadings: routeReadingsSnapshot,
                    liveReadings: liveReadingsSnapshot,
                    latestReading: latestReading,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            }
            let prepared: MapHomePreparedRouteReadings
            do {
                prepared = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
            } catch {
                worker.cancel()
                guard routeReadingsPreparationGeneration.accepts(preparationID) else {
                    return
                }
                routeReadingsPreparationTask = nil
                lastPreparedRouteReadingsSignature = nil
                return
            }
            guard !Task.isCancelled,
                  routeReadingsPreparationGeneration.accepts(preparationID),
                  lastPreparedRouteReadingsSignature == preparationSignature,
                  scenePhase == .active else { return }
            normalizedRouteReadings = prepared.normalized
            if currentMapLocationReading != prepared.latestTrustedReading {
                currentMapLocationReading = prepared.latestTrustedReading
            }
            historicalPlaybackReadings = prepared.normalized
            displayRouteReadings = prepared.display
            routeReadingsPreparationTask = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_route_readings_prepared",
                fields: [
                    "day_start": String(dayStart.timeIntervalSince1970),
                    "source_readings": String(prepared.sourceCount),
                    "impossible_location_count": String(prepared.impossibleLocationCount),
                    "innovation_outlier_count": String(prepared.innovationOutlierCount),
                    "filtered_readings": String(prepared.filteredCount),
                    "normalized_readings": String(prepared.normalized.count),
                    "display_readings": String(prepared.display.count),
                    "watch_source_readings": String(prepared.watchSourceCount),
                    "readings_with_point": String(prepared.readingsWithPointCount),
                    "readings_rail_match": String(prepared.railMatchCount),
                    "readings_station_name": String(prepared.stationNameCount),
                ].merging(
                    MapHomeRouteJumpDiagnostics.fields(for: prepared.display),
                    uniquingKeysWith: { first, _ in first }
                )
            )
            requestRouteProjectionRefresh()
            requestWBSPlaybackProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
    }

    private func requestWBSPlaybackProjectionRefresh() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
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
            if !applyForecastRouteState(pendingForecastRouteState) {
                refreshWBSPlaybackProjection()
            }
            return
        }
        guard hasDeferredWBSPlaybackRefresh else { return }
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
    }

    private func refreshWBSPlaybackProjection() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        hasDeferredWBSPlaybackRefresh = false
        var next = makeWBSPlaybackProjection(
            expected: expectedRouteOverlays,
            generated: wbsGeneratedRouteOverlays
        )
        let activeGeneratedIDs = Set(next.legs.compactMap { leg in
            leg.routePhase == .forecast && leg.activity == .movement
                ? leg.id
                : nil
        })
        let generated = wbsGeneratedRouteOverlays.filter {
            activeGeneratedIDs.contains($0.id)
        }
        if generated.count != wbsGeneratedRouteOverlays.count {
            wbsGeneratedRouteOverlays = generated
            mapRenderCache.invalidateExpectedRoutes()
            next = makeWBSPlaybackProjection(
                expected: expectedRouteOverlays,
                generated: generated
            )
        }
        if wbsPlaybackProjection != next {
            wbsPlaybackProjection = next
        }
    }

    private func makeWBSPlaybackProjection(
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        expectedRouteRequests: [ExpectedRouteRequest]? = nil
    ) -> MapHomeWBSPlaybackProjection {
        let dayData = currentDayDataSnapshot
        let playbackRequests = expectedRouteRequests
            ?? (wbsExpectedRouteRequestsInputKey == currentExpectedRouteInputKey()
                ? wbsExpectedRouteRequests
                : [])
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
            places: dayData?.places ?? [],
            travel: dayData?.travel ?? [],
            readings: currentDayReadings,
            expectedRouteRequests: playbackRequests,
            resolvedRoutes: expectedRoutes + generatedRoutes + storedWBSResolvedRoutes,
            actuals: dayData?.actuals ?? [],
            confirmedSleepSpans: model.settings.confirmedSleepSpans,
            sleepSessions: model.sleepSessions
        )
    }

    private var storedWBSResolvedRoutes: [MapHomeWBSResolvedRoute] {
        (currentDayDataSnapshot?.travel ?? []).compactMap { segment in
            guard segment.mode == .subway,
                  segment.isConfirmed,
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

    private func recordCurrentPlaybackAlignment() {
        if let frame = wbsPlaybackFrame, selectedPawprintPoint == nil {
            recordPlaybackRouteAlignment(frame)
        }
    }

    private func recordPlaybackRouteAlignment(
        _ frame: MapHomeWBSPlaybackFrame
    ) {
        let dottedLegIDs = visibleForecastPlaybackLegIDs
        let cutoffDelta = routeOverlayCutoff.timeIntervalSince(
            displayedLocationDate
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_playback_alignment",
            fields: [
                "frame_leg_id": frame.legID,
                "frame_phase": frame.routePhase.rawValue,
                "frame_activity": frame.activity == .movement
                    ? "movement"
                    : "stay",
                "frame_progress": String(frame.progress),
                "forecast_overlay_count": String(dottedLegIDs.count),
                "frame_matches_forecast_overlay": String(
                    dottedLegIDs.contains(frame.legID)
                ),
                "cutoff_delta_seconds": String(cutoffDelta),
                "is_playback_running": String(isDayPlaybackRunning),
            ]
        )
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
        MapHomeDateText.string(
            from: model.selectedDate,
            format: selectedScope == .day
                ? language.dateTitleFormat
                : language.monthTitleFormat,
            locale: language.locale
        )
    }

    private var dateTitleLabel: Text {
        let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: model.selectedDate)
        let weekdayName = MapHomeDateText.string(
            from: model.selectedDate, format: language.weekdayFormat, locale: language.locale)
        let weekdayText = Text(" \(weekdayName)")
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(dateColor(weekday: weekday))
        return datePartTitleLabel + weekdayText
    }

    private var datePartTitleLabel: Text {
        let datePart = MapHomeDateText.string(
            from: model.selectedDate, format: language.datePartFormat, locale: language.locale)
        return Text(datePart)
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
        if weekday == 7 { return .tpSaturday }
        if TimelineAxisGrid.koreanHolidayName(on: model.selectedDate) != nil || weekday == 1 {
            return .tpHoliday
        }
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

    private func setMapPosition(_ position: MapCameraPosition, caller: String = #function) {
        mapPosition = position
        mapCameraRevision &+= 1
        // 재생 중에는 초당 한 번만 기록해 로그 양을 줄인다.
        if isDayPlaybackRunning,
           !MapHomeCameraLogThrottle.shouldLog(nowUptime: ProcessInfo.processInfo.systemUptime) { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_camera_command",
            fields: [
                "caller": caller,
                "tracking": String(describing: userTrackingMode),
                "playing": isDayPlaybackRunning ? "true" : "false",
            ],
            metrics: [
                "revision": Double(mapCameraRevision),
                "distance_m": position.camera?.distance.rounded() ?? -1,
            ]
        )
    }

    private func restoreInitialMapZoom() {
        let camera = MapHomeStartupCameraPolicy.camera(
            restoring: visibleMapCamera,
            fallbackCenter: displayedLocationCoordinate ?? currentCoordinate
                ?? MapHomeStartupCameraPolicy.fallbackCenter
        )
        mapCameraFrameProjection.reset()
        if visibleMapCamera != camera { visibleMapCamera = camera }
        setMapPosition(.camera(camera))
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
        applyInitialMapFocusIfNeeded()
    }

    private func applyInitialMapFocusIfNeeded() {
        guard !isDayPlaybackRunning, !hasUserAdjustedMap,
              !hasAppliedInitialMapFocus,
              let coordinate = displayedLocationCoordinate ?? currentCoordinate else { return }
        hasAppliedInitialMapFocus = true
        hasAppliedInitialLocation = true
        setMapPosition(.camera(MapCamera(centerCoordinate: coordinate, distance: MapHomeStartupCameraPolicy.distance)))
    }

    private var mapRouteFitRegion: MKCoordinateRegion? {
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + displayedExpectedRouteOverlays.flatMap(\.coordinates)
            + displayedWBSGeneratedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        if coordinates.isEmpty, let currentCoordinate {
            coordinates = [currentCoordinate]
        }
        return MapHomeRouteFitMath.region(for: coordinates)
    }

    private func sharedZoomLevel(for span: MKCoordinateSpan) -> CGFloat? {
        guard let bounds = mapRenderCache.bounds(
            timeline: timelineRouteOverlays,
            expected: displayedExpectedRouteOverlays,
            generated: displayedWBSGeneratedRouteOverlays,
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

    /// 배율 숫자를 누르면 이동 경로 전체가 보이도록 배율과 위치를 맞춘다. 따라가기는 멈춘다.
    private func fitMapToRoutes() {
        guard !isDayPlaybackRunning, let region = mapRouteFitRegion else { return }
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
        hasUserAdjustedMap = true
        setMapPosition(.region(region))
    }

    /// 집 위치로 카메라를 옮긴다. 땅 한 칸이 보이는 거리(집 주변 땅 타일의 최소 표시 크기 이상)로 확대한다.
    private func focusMapOnHome() {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return }
        hasUserAdjustedMap = true
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
                distance: 70,
                heading: 0,
                pitch: 0
            )
        ))
    }

    private func focusMapOnAllRoutes() {
        guard MapHomePlaybackCameraPolicy.allowsAutomaticFit(
            isPlaybackRunning: isDayPlaybackRunning,
            hasUserAdjustedMap: hasUserAdjustedMap
        ) else { return }
        guard let region = mapRouteFitRegion else {
            setMapPosition(.automatic)
            return
        }
        setMapPosition(.region(region))
    }

    /// 실시간 따라가기 중 최신 센서 속도. 오래된 값은 쓰지 않는다.
    private var liveFollowSpeedMetersPerSecond: Double? {
        guard let reading = model.latestSensorReading else { return nil }
        return MapHomeLiveFollowSpeed.speed(
            latestAge: Date.now.timeIntervalSince(reading.timestamp),
            latestSpeed: reading.speedMetersPerSecond
        )
    }

    /// 재생 중 화랑이가 화면 가운데에서 얼마나 벗어났는지 1초에 한 번 기록한다(좌표 없이 픽셀과 유무만).
    private func recordPlaybackFocusSample() {
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastPlaybackFocusLogUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime,
            minimumInterval: 1
        ) else { return }
        let center = currentLocationTargetPoint
        let offset = displayedStickmanViewportPoint.map {
            hypot($0.x - center.x, $0.y - center.y)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_focus_sample",
            metrics: [
                "has_point": displayedPlaybackFocusPoint == nil ? 0 : 1,
                "has_camera": visibleMapCamera == nil ? 0 : 1,
                "stickman_offset_px": offset?.rounded() ?? -1,
                "camera_distance_m": visibleMapCamera?.distance.rounded() ?? -1,
                "speed_mps": displayedSpeedMetersPerSecond ?? -1,
            ]
        )
    }

    /// Apple 지도의 재생 중 속도 비례 줌. 가운데 맞추기는 지도 뷰가 하고, 여기서는 거리만 바꾼다.
    private func advanceApplePlaybackZoom() {
        guard isDayPlaybackRunning,
              !isPlaybackIntroActive,
              TimelineInteractionFrameGate.shouldRender(
                  lastUptime: &lastPlaybackMapFocusUptime,
                  nowUptime: ProcessInfo.processInfo.systemUptime,
                  minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
              ),
              let camera = visibleMapCamera,
              let point = displayedPlaybackFocusPoint else { return }
        let next = playbackAwareDistance(current: camera.distance)
        guard abs(next - camera.distance) / camera.distance >= 0.01 else { return }
        requestAppleMapCenter(
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            distance: next
        )
    }

    /// 멈춰 있어 새 위치가 오지 않아도 기본 거리까지 확대를 이어 간다(2초 간격 한 걸음씩).
    private func advanceStationaryZoomIfNeeded() {
        guard scenePhase == .active,
              MapHomeUserTrackingPolicy.focusesLocationUpdates(in: userTrackingMode),
              liveFollowSpeedMetersPerSecond == 0,
              let camera = visibleMapCamera,
              abs(log(camera.distance / MapHomePlaybackZoomPolicy.baselineDistance)) >= MapHomeLiveZoomGovernor.hysteresis
        else { return }
        focusDisplayedLocation(using: nil)
    }

    /// 오늘의 실시간 따라가기에서 속도에 맞춘 거리. 바꾸지 않아야 하면 nil.
    private func liveFollowDistance(current: Double) -> Double? {
        guard !isDayPlaybackRunning,
              selectedTimelineMinute == nil,
              userTrackingMode == .following,
              Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
              let next = liveZoomGovernor.nextDistance(
                  current: current,
                  speedMetersPerSecond: liveFollowSpeedMetersPerSecond,
                  uptime: ProcessInfo.processInfo.systemUptime
              ), abs(next - current) >= 1 else { return nil }
        TaptionPlanDiagnosticsLogger.shared.record(
            "live_zoom_sample",
            metrics: [
                "speed_mps": liveFollowSpeedMetersPerSecond ?? -1,
                "current_m": current.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
    }

    /// 재생 중에는 속도에 맞춘 거리를, 실시간 따라가기에서는 속도 비례 줌을, 아니면 현재 거리를 돌려준다.
    private func playbackAwareDistance(current: Double) -> Double {
        guard isDayPlaybackRunning else {
            return liveFollowDistance(current: current) ?? current
        }
        guard MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed else {
            return current
        }
        let playbackMinute = dayPlaybackCurrentMinute ?? Double(selectedTimelineMinute ?? 0)
        let target = playbackZoomPlan.targetDistance(
            atMinute: playbackMinute,
            speedMetersPerSecond: displayedSpeedMetersPerSecond
        )
        let next = playbackZoomSmoother.next(
            current: current,
            target: target,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_zoom_sample",
            metrics: [
                "plan_scale": playbackZoomPlan.scale(atMinute: playbackMinute),
                "current_m": current.rounded(),
                "target_m": target.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
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
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
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
            requestAppleMapCenter(coordinate)
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
            guard let point = displayedPlaybackFocusPoint else { return }
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
        guard let coordinate = liveFocusCoordinate else {
            isMapCenteredOnUser = false
            return
        }

        if preservesCamera, !rendersVectorMap {
            let distance = visibleMapCamera.flatMap {
                liveFollowDistance(current: $0.distance)
            }
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate, distance: distance)
            } else {
                requestAppleMapCenter(coordinate, distance: distance)
            }
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
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
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
        if !rendersVectorMap {
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate)
            } else {
                requestAppleMapCenter(coordinate)
            }
        }
    }

    private func requestAppleMapCenter(
        _ coordinate: CLLocationCoordinate2D,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: nil,
            targetPoint: currentLocationTargetPoint,
            distance: distance
        )
    }

    private func requestAppleMapHeading(
        _ heading: CLLocationDirection,
        centeredAt coordinate: CLLocationCoordinate2D?,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: heading,
            targetPoint: coordinate == nil ? nil : currentLocationTargetPoint,
            distance: distance
        )
    }

    private func requestAndFollowUserLocation(using proxy: MapProxy?) {
        // 위치 버튼으로 다시 따라가기 시작하면 자동 줌 일시 정지를 푼다.
        liveZoomGovernor.reset()
        hasCancelledInitialLocationFocus = false
        setUserTrackingMode(.locating)
        // GPS를 기다리는 동안에도 가장 최근 위치로 먼저 이동해 화랑이를 보여준다.
        focusUserLocation(using: proxy, preservesCamera: true)
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = Task { @MainActor in
            defer { currentLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  userTrackingMode.keepsCameraLocked else { return }
            guard isAvailable || liveFocusCoordinate != nil else {
                setUserTrackingMode(.idle)
                return
            }
            if isAvailable { setUserTrackingMode(.following) }
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
                heading: compassControlState.mapCameraHeading,
                preservesCamera: true
            )
        }
    }

    private func applyMapHeading(using proxy: MapProxy?) {
        guard isHeadingMode else { return }
        let heading = headingMonitor.headingDegrees
            ?? visibleMapCamera?.heading
            ?? 0
        if currentCoordinate != nil {
            focusUserLocation(
                using: proxy,
                heading: heading,
                preservesCamera: true
            )
            setUserTrackingMode(.following)
        } else {
            requestAppleMapHeading(heading, centeredAt: nil)
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
        applyInitialMapFocusIfNeeded()
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
            applyInitialMapFocusIfNeeded()
        }
    }

    private func setUserTrackingMode(_ mode: MapHomeUserTrackingMode) {
        guard userTrackingModeRawValue != mode.rawValue else { return }
        userTrackingModeRawValue = mode.rawValue
    }

    private func handleUserMapPan() {
        // 재생 중 지도를 직접 끌면 재생을 멈추고 그 시각에 머문다.
        if isDayPlaybackRunning {
            stopDayPlayback(resetProgress: true)
        }
        recordUserMapAdjustment()
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    private func handleUserCameraGesture() {
        recordUserMapAdjustment()
    }

    private func recordUserMapAdjustment() {
        liveZoomGovernor.pauseForUserAdjustment(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        hasUserAdjustedMap = true
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        appleViewportCommand = nil
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
        if let locationPoint {
            submitDisplayedStickmanViewportPoint(locationPoint)
        } else if displayedLocationCoordinate == nil {
            displayedStickmanViewportPoint = nil
        }
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
        let title = selectedMovementMode.map {
            MapHomeMovementEditOption.localizedTitle(
                for: $0,
                language: language
            )
        } ?? selectedCategory.localizedTitle(language)
        let systemImage = selectedMovementMode.map {
            MovementPresentation.symbol(for: $0)
        } ?? selectedCategory.systemImage

        return Menu {
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
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            language.text("대분류 수정 \(title)", "Edit category \(title)")
        )
        .accessibilityHint(
            language.text(
                "탭해서 대분류를 변경합니다.",
                "Tap to change the category."
            )
        )
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
    @State private var backupPassword = ""
    @State private var remembered: String?
    @State private var message: String?
    @State private var restoreTarget: PlanBackupListingRow?
    @State private var isOffloadConfirmationPresented = false
    @FocusState private var focusedField: PINField?

    private enum PINField { case pin, confirmation, backup }
    /// 등록된 비밀번호는 다시 보여줄 수 없으므로, 등록돼 있으면 빈 칸 대신 점 6개로 표시한다.
    private var registeredPINDots: String { String(repeating: "●", count: securityPINDigits) }

    private var security: PlanSecurityStatus { model.securityStatus }
    private var hasPIN: Bool { security.hasPIN }
    private var securityPINDigits: Int { security.pinDigits }
    private var appLockEnabled: Bool {
        security.settings.lockOnLaunch && security.settings.lockOnForeground
    }
    private var activity: PlanBackupActivity { model.backupActivity }
    private var isBusy: Bool { activity.isBusy }
    /// 기기에 보관된 비밀번호가 있으면 그것을, 없으면(기존 사용자 첫 1회) 입력한 값을 쓴다.
    private var password: String { remembered ?? backupPassword }
    private var needsPasswordEntry: Bool { hasPIN && remembered == nil }
    private var canUseBackupPassword: Bool {
        hasPIN && password.count == securityPINDigits && !isBusy
    }

    private func refreshRemembered() {
        let value = model.rememberedBackupPassword
        guard value != remembered else { return }
        remembered = value
        if let value { Task { await model.refreshBackupListings(password: value) } }
    }

    /// 백업 버튼이 꺼져 있을 때 이유를 알려 준다. 켜져 있으면 nil.
    private var backupDisabledReason: String? {
        if !model.backupDestinationAvailable {
            return language.text("백업 저장소를 열지 못했습니다. 앱을 다시 실행해 주세요.", "The backup store could not be opened. Relaunch the app.")
        }
        if !hasPIN {
            return language.text("먼저 위에서 앱 비밀번호(6자리)를 등록해야 백업할 수 있습니다.", "Register an app password (6 digits) above first to back up.")
        }
        if isBusy { return nil }
        if password.count != securityPINDigits {
            return language.text("비밀번호 \(securityPINDigits)자리를 입력하면 버튼이 켜집니다.", "Enter your \(securityPINDigits)-digit password to enable the button.")
        }
        return nil
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
                            ? language.text("\(securityPINDigits)자리 비밀번호 등록됨", "\(securityPINDigits)-digit password registered")
                            : language.text("백업 전 비밀번호 등록 필요", "Set a password before backup")
                        )
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(language.text("닫기", "Close")) { dismiss() }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }

                card(language.text("iCloud 로그 업로드", "iCloud Log Upload")) {
                    Text(language.text(
                        "iPhone·Apple Watch 진단 로그와 직전 비정상 종료 상태를 iCloud Drive의 TaptionLogs에 저장합니다.",
                        "Saves iPhone and Apple Watch diagnostics plus the previous unfinished session to TaptionLogs in iCloud Drive."
                    ))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.exportDiagnosticsToICloud() }
                        } label: {
                            Label(
                                language.text("로그 업로드", "Upload logs"),
                                systemImage: "icloud.and.arrow.up"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.tpReferenceBlue)
                        .disabled(model.isExportingDiagnostics)

                        Text(model.diagnosticsExportStatus)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpReferenceBlue)
                    }

                    Text(model.diagnosticsLatestLogSummary)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                card(language.text("\(PlanPINVerifier.currentDigits)자리 비밀번호", "\(PlanPINVerifier.currentDigits)-digit password")) {
                    SecureField(hasPIN ? registeredPINDots : language.text("비밀번호", "Password"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .pin)
                        .onChange(of: pin) { _, value in pin = numericPIN(value) }
                    SecureField(hasPIN ? registeredPINDots : language.text("비밀번호 확인", "Confirm password"), text: $confirmation)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmation)
                        .onChange(of: confirmation) { _, value in confirmation = numericPIN(value) }
                    Button(language.text("비밀번호 저장", "Save password")) {
                        savePIN()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpReferenceRose)
                    .disabled(pin.count != PlanPINVerifier.currentDigits
                        || confirmation.count != PlanPINVerifier.currentDigits)
                    Text(language.text(
                        "비밀번호를 바꾸면 그 뒤에 만드는 백업부터 새 비밀번호를 씁니다. 바꾸기 전에 만든 백업 파일은 그때의 비밀번호로 열립니다.",
                        "After you change the password, new backups use it. Backup files made earlier still open with the password used at that time."
                    ))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
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

                backupCard
                offloadCard
                restoreCard

                if let message {
                    Text(message)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .padding(22)
            // 비밀번호 칸 밖의 빈 곳을 누르면 숫자 키패드를 내린다.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = nil }
            )
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.tpSurface)
        .task { await model.refreshBackupListings() }
        .onAppear { refreshRemembered() }
        .onChange(of: isBusy) { _, _ in refreshRemembered() }
        .onChange(of: hasPIN) { _, _ in refreshRemembered() }
        .alert(
            language.text("이 달을 불러올까요?", "Restore this month?"),
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            )
        ) {
            Button(language.text("취소", "Cancel"), role: .cancel) { restoreTarget = nil }
            Button(language.text("불러오기", "Restore")) { restoreConfirmed() }
        } message: {
            Text(language.text(
                "\(restoreTarget.map(title(of:)) ?? "")의 백업을 이 기기로 가져옵니다. 이 기기에 더 새로운 기록이 있으면 그대로 유지됩니다. 위 입력란의 비밀번호는 그 백업을 만들 때 쓴 비밀번호여야 합니다.",
                "Brings the backup for \(restoreTarget.map(title(of:)) ?? "") onto this device. Newer records already on this device are kept. The password above must be the one used when that backup was made."
            ))
        }
        .alert(
            language.text("로컬 정리", "Clear from this device"),
            isPresented: $isOffloadConfirmationPresented
        ) {
            Button(language.text("취소", "Cancel"), role: .cancel) {}
            Button(language.text("정리", "Clear"), role: .destructive) { offload() }
        } message: {
            Text(language.text(
                "최근 \(security.localMonthsToKeep)개 달을 뺀 지난 달 중 백업을 다시 읽어 확인된 달만 이 기기에서 지웁니다. 지운 달은 백업 목록에서 다시 불러올 수 있습니다.",
                "Past months older than the latest \(security.localMonthsToKeep) are removed from this device only after their backup is read back and verified. You can restore them from the backup list."
            ))
        }
    }

    // MARK: 카드

    private var backupCard: some View {
        card(language.text("iCloud 백업", "iCloud Backup")) {
            Text(language.text(
                "iCloud Drive/TaptionBackup에 달마다 파일 하나로 압축·암호화해 저장합니다. 자동으로 올리지 않으며, ‘지금 백업’을 누를 때만 올립니다.",
                "Saved to iCloud Drive/TaptionBackup as one compressed, encrypted file per month. Nothing is uploaded automatically; it runs only when you tap Back up now."
            ))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            if needsPasswordEntry {
                SecureField(language.text("비밀번호", "Password"), text: $backupPassword)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .backup)
                    .textContentType(.password)
                    .onChange(of: backupPassword) { _, value in
                        backupPassword = numericPIN(value)
                        let shown = backupPassword.count == securityPINDigits ? backupPassword : nil
                        Task { await model.refreshBackupListings(password: shown) }
                    }
            }
            if let latestBackupText {
                Text(language.text(
                    "마지막 백업: \(latestBackupText)",
                    "Last backup: \(latestBackupText)"
                ))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpReferenceBlue)
            }
            if case .backingUp(let completed, let total) = activity {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text(language.text("백업 중 \(completed)/\(total)", "Backing up \(completed)/\(total)"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Button(language.text(isBusy ? "작업 중입니다" : "지금 백업", isBusy ? "Working" : "Back up now")) {
                let password = self.password
                Task { await model.backUpNow(password: password) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpReferenceBlue)
            .disabled(!canUseBackupPassword || !model.backupDestinationAvailable)
            if let reason = backupDisabledReason {
                Text(reason)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let report = model.lastBackupReport, report.operation == .backup {
                reportView(report)
            }
        }
    }

    private var offloadCard: some View {
        card(language.text("백업 후 로컬 정리", "Clear from device after backup")) {
            Stepper(
                value: Binding(
                    get: { security.localMonthsToKeep },
                    set: { model.setLocalMonthsToKeep($0) }
                ),
                in: PlanSecurityService.localMonthsToKeepRange
            ) {
                Text(language.text(
                    "이 기기에 남길 최근 \(security.localMonthsToKeep)개 달(이번 달 포함)",
                    "Keep the latest \(security.localMonthsToKeep) months on this device (this month included)"
                ))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Text(language.text(
                "백업을 다시 읽어 확인된 지난 달만 이 기기에서 지웁니다. 먼저 ‘지금 백업’을 해야 하며, 설정은 지우지 않습니다.",
                "Only past months whose backup was read back and verified are removed from this device. Run ‘Back up now’ first; settings are never removed."
            ))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            if case .offloading = activity {
                ProgressView().controlSize(.small)
            }
            Button(language.text("백업 후 로컬 정리", "Clear after backup")) {
                isOffloadConfirmationPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(!canUseBackupPassword || !model.backupDestinationAvailable)
            if let report = model.lastBackupReport, report.operation == .offload {
                reportView(report)
            }
        }
    }

    private var restoreCard: some View {
        card(language.text("백업 목록과 복원", "Backups and restore")) {
            Text(language.text(
                "월 이름과 파일 크기는 바로 보이고, 행 수와 마지막 기록 시각은 비밀번호를 넣은 뒤 보입니다. 백업은 앱 비밀번호와 같은 비밀번호로 열립니다.",
                "Row counts and times appear once the password is known. Backups open with your app password."
            ))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            if case .restoring(let name) = activity {
                ProgressView(language.text("\(name) 불러오는 중", "Restoring \(name)"))
                    .controlSize(.small)
            }
            if model.backupListings.isEmpty {
                Text(model.backupListingError
                    ?? language.text("iCloud에 백업 파일이 없습니다.", "No backup files in iCloud."))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.backupListings) { row in
                listingRow(row)
            }
            Button {
                let shown = password.count == securityPINDigits ? password : nil
                Task { await model.refreshBackupListings(password: shown) }
            } label: {
                Label(language.text("목록 새로고침", "Refresh list"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            if let report = model.lastBackupReport, report.operation == .restore {
                reportView(report)
            }
        }
    }

    private func listingRow(_ row: PlanBackupListingRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(of: row))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(listingDetail(row))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if row.isOffloaded {
                    Text(language.text("이 기기에서는 정리됨 · 불러올 수 있음", "Cleared from this device · can be restored"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            Spacer(minLength: 8)
            Button(language.text("불러오기", "Restore")) {
                guard !password.isEmpty else {
                    message = language.text(
                        "비밀번호를 먼저 입력해 주세요.",
                        "Enter your password first."
                    )
                    return
                }
                restoreTarget = row
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || !row.isReadable)
        }
    }

    private func reportView(_ report: PlanBackupReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(report.summary)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(report.succeeded ? Color.tpReferenceBlue : Color.tpReferenceRose)
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(item.kind == .rejected ? Color.tpReferenceRose : Color.tpReferenceBlue)
                    Text("\(item.name == "settings" ? language.text("설정", "Settings") : item.name) · \(item.detail)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func icon(for kind: PlanBackupItem.Kind) -> String {
        switch kind {
        case .done: "checkmark.circle.fill"
        case .unchanged: "equal.circle.fill"
        case .rejected: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle.fill"
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

    // MARK: 동작

    private func numericPIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(PlanPINVerifier.currentDigits))
    }

    private func savePIN() {
        guard pin == confirmation else {
            message = language.text("비밀번호 확인이 일치하지 않습니다.", "Passwords do not match.")
            return
        }
        perform {
            try model.configureBackupPIN(pin)
            refreshRemembered()
            focusedField = nil
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

    private func configure(_ value: PlanAppLockSettings) {
        perform {
            try model.configureAppLock(value)
            message = language.text("보안 설정을 저장했습니다.", "Security settings saved.")
        }
    }

    private func offload() {
        let password = self.password
        Task { await model.offloadLocalMonths(password: password) }
    }

    private func restoreConfirmed() {
        guard let target = restoreTarget else { return }
        restoreTarget = nil
        let password = self.password
        Task { await model.restoreBackup(target.scope, password: password) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: 표시 문구

    private func title(of row: PlanBackupListingRow) -> String {
        switch row.scope {
        case .settings:
            return language.text("설정", "Settings")
        case .month(let month):
            return language.text("\(month.year)년 \(month.month)월", "\(month.month)/\(month.year)")
        }
    }

    private func listingDetail(_ row: PlanBackupListingRow) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file)
        guard row.metadataShown else {
            return language.text("\(size) · 비밀번호를 넣으면 행 수와 시각이 보입니다", "\(size) · enter the password to see rows and times")
        }
        guard row.isReadable, let rows = row.rowCount else {
            return language.text("\(size) · 열 수 없음(내려받는 중이거나 손상됨)", "\(size) · unreadable (still downloading or damaged)")
        }
        var parts = [size, language.text("\(rows)행", "\(rows) rows")]
        if let last = row.lastDataAt {
            parts.append(language.text("마지막 기록 \(formatted(last))", "last record \(formatted(last))"))
        }
        if let created = row.createdAt {
            parts.append(language.text("백업 \(formatted(created))", "backed up \(formatted(created))"))
        }
        return parts.joined(separator: " · ")
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var latestBackupText: String? {
        security.latestSuccessfulBackupDate.map(formatted)
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
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double]? = nil
    ) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2,
              departureDate <= date,
              date <= arrivalDate,
              arrivalDate > departureDate else { return nil }

        guard let fraction = progress(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate
        ) else { return nil }
        return coordinate(
            atProgress: fraction,
            coordinates: coordinates,
            segmentLengths: segmentLengths
        )
    }

    static func segmentLengths(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [Double] {
        zip(coordinates, coordinates.dropFirst()).map {
            CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)
                .distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
        }
    }

    static func coordinate(
        atProgress progress: Double,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths cachedLengths: [Double]? = nil
    ) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return coordinates.first }
        let lengths = cachedLengths?.count == coordinates.count - 1
            ? cachedLengths!
            : segmentLengths(for: coordinates)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return coordinates.first }
        let target = total * min(max(progress, 0), 1)
        var traversed = 0.0
        for (index, length) in lengths.enumerated() {
            guard length > 0 else { continue }
            let next = coordinates[index + 1]
            if traversed + length >= target {
                let ratio = min(max((target - traversed) / length, 0), 1)
                return CLLocationCoordinate2D(
                    latitude: coordinates[index].latitude
                        + (next.latitude - coordinates[index].latitude) * ratio,
                    longitude: RouteTimelineLongitude.interpolate(
                        from: coordinates[index].longitude,
                        to: next.longitude,
                        fraction: ratio
                    )
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
                    longitude: RouteTimelineLongitude.interpolate(
                        from: points[index].longitude,
                        to: next.longitude,
                        fraction: ratio
                    ),
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
    let segmentID: UUID
    let mode: TravelMode
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]
    let segmentLengths: [Double]
    let geometrySignature: Int

    init(
        id: UUID,
        segmentID: UUID,
        mode: TravelMode,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.segmentID = segmentID
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        segmentLengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(
            for: coordinates
        )
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }

    private init(
        id: UUID,
        segmentID: UUID,
        mode: TravelMode,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double],
        geometrySignature: Int
    ) {
        self.id = id
        self.segmentID = segmentID
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        self.segmentLengths = segmentLengths
        self.geometrySignature = geometrySignature
    }

    func coordinate(at date: Date) -> CLLocationCoordinate2D? {
        MapHomeExpectedRoutePlaybackMath.coordinate(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: coordinates,
            segmentLengths: segmentLengths
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
        let visible = Self.prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: segmentLengths
        )
        return Self(
            id: id,
            segmentID: segmentID,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: visible.coordinates,
            segmentLengths: visible.segmentLengths,
            geometrySignature: MapHomeRouteGeometrySignature.derived(
                from: geometrySignature,
                coordinates: visible.coordinates
            )
        )
    }

    fileprivate static func prefixByDistance(
        _ coordinates: [CLLocationCoordinate2D],
        fraction: Double,
        segmentLengths cachedLengths: [Double]? = nil
    ) -> [CLLocationCoordinate2D] {
        prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: cachedLengths
        ).coordinates
    }

    fileprivate struct PrefixResult {
        let coordinates: [CLLocationCoordinate2D]
        let segmentLengths: [Double]
    }

    fileprivate static func prefixByDistanceResult(
        _ coordinates: [CLLocationCoordinate2D],
        fraction: Double,
        segmentLengths cachedLengths: [Double]? = nil
    ) -> PrefixResult {
        guard coordinates.count >= 2 else {
            return PrefixResult(coordinates: coordinates, segmentLengths: [])
        }
        let lengths = cachedLengths?.count == coordinates.count - 1
            ? cachedLengths!
            : MapHomeExpectedRoutePlaybackMath.segmentLengths(for: coordinates)
        let total = lengths.reduce(0, +)
        guard total > 0 else {
            return PrefixResult(
                coordinates: Array(coordinates.prefix(2)),
                segmentLengths: [0]
            )
        }

        let target = total * min(max(fraction, 0), 1)
        var traversed = 0.0
        var result = [coordinates[0]]
        var resultLengths: [Double] = []
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
                        longitude: RouteTimelineLongitude.interpolate(
                            from: coordinates[index].longitude,
                            to: next.longitude,
                            fraction: ratio
                        )
                    )
                )
                resultLengths.append(length * ratio)
                return PrefixResult(
                    coordinates: result.count >= 2
                        ? result
                        : Array(coordinates.prefix(2)),
                    segmentLengths: result.count >= 2
                        ? resultLengths
                        : [length]
                )
            }
            result.append(next)
            resultLengths.append(length)
            traversed += length
        }
        return PrefixResult(
            coordinates: coordinates,
            segmentLengths: lengths
        )
    }
}

private struct MapHomeWBSGeneratedRouteOverlay: Identifiable {
    let id: String
    let mode: TravelMode?
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]
    let segmentLengths: [Double]
    let geometrySignature: Int

    init(
        id: String,
        mode: TravelMode?,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        segmentLengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(
            for: coordinates
        )
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }

    private init(
        id: String,
        mode: TravelMode?,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double],
        geometrySignature: Int
    ) {
        self.id = id
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        self.segmentLengths = segmentLengths
        self.geometrySignature = geometrySignature
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
        let visible = MapHomeExpectedRouteOverlay.prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: segmentLengths
        )
        return Self(
            id: id,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: visible.coordinates,
            segmentLengths: visible.segmentLengths,
            geometrySignature: MapHomeRouteGeometrySignature.derived(
                from: geometrySignature,
                coordinates: visible.coordinates
            )
        )
    }
}

private struct MapHomeExpectedRouteRequestBatch: Sendable {
    let overlayRequests: [ExpectedRouteRequest]
    let playbackRequests: [ExpectedRouteRequest]
    let overlayOperationCount: Int
    let playbackOperationCount: Int
    let readingsWithPointCount: Int
    let unconfirmedTravelCount: Int
}

private struct MapHomeExpectedRouteInputKey: Equatable, Sendable {
    let selectedDay: Date
    let dayEnd: Date
    let dayProjectionRevision: UInt64
    let daySourceRevision: UInt64?
    let daySourceUpdatedAt: Date?
    let daySourceFingerprint: String?
    let isPreview: Bool
    let readingsPreparationID: UUID
    let normalizedReadings: MapHomeDayCacheReadingsFingerprint
    let normalizedLastRouteInputSignature: String
    let liveReadings: MapHomeDayCacheReadingsFingerprint
    let liveLastUpdatedAt: Date?
    let liveLastRouteInputSignature: String
    let latestRouteInputSignature: String
}

private struct MapHomeForecastRouteState {
    let expected: [MapHomeExpectedRouteOverlay]
    let generated: [MapHomeWBSGeneratedRouteOverlay]
    let refreshGeneration: UInt64
    let inputKey: MapHomeExpectedRouteInputKey
}

struct MapHomeSubwayRouteOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let estimated: Bool
    let geometrySignature: Int
    let travelID: UUID?

    init(
        id: UUID,
        coordinates: [CLLocationCoordinate2D],
        estimated: Bool,
        travelID: UUID? = nil
    ) {
        self.id = id
        self.coordinates = coordinates
        self.estimated = estimated
        self.travelID = travelID
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }
}

final class MapHomeSubwayRouteCache {
    private var day: Date?
    private var minute: Int?
    private var revision: UInt64?
    private var overlays: [MapHomeSubwayRouteOverlay] = []

    func invalidate() {
        minute = nil
        revision = nil
    }

    func restore(day: Date, overlays: [MapHomeSubwayRouteOverlay]) {
        self.day = day
        self.overlays = overlays
        invalidate()
    }

    func routes(day: Date, minute: Int, sourceRevision: UInt64?,
                make: () -> [MapHomeSubwayRouteOverlay]) -> [MapHomeSubwayRouteOverlay] {
        // Camera redraws can arrive before the next immutable day snapshot is ready.
        // Missing input is not an authoritative empty route list.
        guard let sourceRevision else { return self.day == day ? overlays : [] }
        if self.day != day || self.minute != minute || revision != sourceRevision {
            overlays = make()
            self.day = day
            self.minute = minute
            revision = sourceRevision
        }
        return overlays
    }
}

enum MapHomeSubwayRouteOverlayEngine {
    static func overlays(
        travel: [TravelSegment],
        readings: [SensorReading],
        day: TimeSpan,
        through cutoff: Date
    ) -> [MapHomeSubwayRouteOverlay] {
        guard cutoff > day.start else { return [] }
        let observedReadings = readings.filter {
            $0.timestamp >= day.start && $0.timestamp < day.end && $0.timestamp <= cutoff
        }
        let readingIndex = SensorEvidenceTimeIndex(readings: observedReadings)
        let subwaySegments = travel
            .filter {
                $0.mode == .subway
                    && $0.isConfirmed
                    && $0.span.start <= cutoff
                    && $0.span.intersection(with: day) != nil
            }
            .sorted { $0.span.start < $1.span.start }
        let resolvedSubwaySegments = subwaySegments.compactMap {
            SubwayTravelSegmentEngine.confirmedRoute(for: $0, readingIndex: readingIndex)
        }
        let confirmed = resolvedSubwaySegments.compactMap {
            resolved -> MapHomeSubwayRouteOverlay? in
            let prefix = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                for: resolved,
                through: cutoff
            )
            let points: [GeoPoint]
            if resolved.span.start < day.start,
               let dayStartPoint = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                   for: resolved, through: day.start).last {
                let oldCount = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                    for: resolved, through: day.start).count
                points = [dayStartPoint] + prefix.dropFirst(max(0, oldCount - 1))
            } else {
                points = prefix
            }
            return makeOverlay(
                id: resolved.id,
                points: points,
                estimated: false,
                travelID: resolved.id
            )
        }

        let railCandidates = travel
            .filter {
                ($0.mode == .train || ($0.mode == .subway && $0.isConfirmed
                    && $0.subwayRoute.map(SubwayStationCatalog.isValid) != true))
                    && $0.span.start <= cutoff
                    && $0.span.intersection(with: day) != nil
            }
            .sorted { $0.span.start < $1.span.start }
        guard !railCandidates.isEmpty else { return confirmed }

        let inferredSubway = SubwayTravelSegmentEngine.segments(
            from: observedReadings,
            within: railCandidates.map(\.span)
        )
        var seenRoutes = Set(resolvedSubwaySegments.compactMap(\.subwayRoute))
        let estimated = railCandidates.compactMap { candidate -> MapHomeSubwayRouteOverlay? in
            // A short confirmed fragment must not hide the rest of an observed rail journey.
            guard let inferred = inferredSubway
                    .filter({ hasSubstantialOverlap($0.span, candidate.span) })
                    .max(by: { $0.span.duration < $1.span.duration }),
                  let route = inferred.subwayRoute,
                  SubwayStationCatalog.isValid(route),
                  seenRoutes.insert(route).inserted else {
                return nil
            }
            return makeOverlay(
                id: confirmed.contains(where: { $0.id == candidate.id }) ? inferred.id : candidate.id,
                points: route.coordinates,
                estimated: true,
                travelID: candidate.id
            )
        }
        return confirmed + estimated
    }

    private static func hasSubstantialOverlap(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Bool {
        guard let overlap = lhs.intersection(with: rhs) else { return false }
        let shorter = max(1, min(lhs.duration, rhs.duration))
        return overlap.duration / shorter >= 0.5
    }

    private static func makeOverlay(
        id: UUID,
        points: [GeoPoint],
        estimated: Bool,
        travelID: UUID
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
            estimated: estimated,
            travelID: travelID
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
    let geometrySignature: Int
    let coordinateTimestamps: [Date]

    init(
        id: String,
        categoryID: String,
        opacity: Double,
        speedMetersPerSecond: Double?,
        coordinates: [CLLocationCoordinate2D],
        coordinateTimestamps: [Date]
    ) {
        self.id = id
        self.categoryID = categoryID
        self.opacity = opacity
        self.speedMetersPerSecond = speedMetersPerSecond
        self.coordinates = coordinates
        self.coordinateTimestamps = coordinateTimestamps
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }
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
    let growthLevel: Int?
    let isLeapDay: Bool
    let growthStatus: String?
    let isGrowthQualifiedToday: Bool
    let growthStreak: Int
    let pendingWeeklyRewards: Int
    let isCatAtHome: Bool
    let catAction: MapHomeStickmanAction
    let equippedAccessoryID: String?
    let coordinate: CLLocationCoordinate2D
    /// 집 핀 위에 올리는 현재 날씨(집에만, 데이터가 없으면 nil).
    var weatherBadge: MapHomeHomeWeatherBadge? = nil
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
    var growthLevel: Int? = nil
    var isLeapDay = false
    var growthStatus: String? = nil
    var isGrowthQualifiedToday = false
    var growthStreak = 0
    var pendingWeeklyRewards = 0
    var showsCatAtHome = false
    var catAction: MapHomeStickmanAction = .activity
    var equippedAccessoryID: String? = nil
    var weatherBadge: MapHomeHomeWeatherBadge? = nil
    var onOpenDaySummary: (() -> Void)? = nil
    @State private var isGrowthSummaryExpanded = false
    @State private var isGrowthCalloutVisible = false

    var body: some View {
        VStack(spacing: 5) {
            if destination == .home, let growthLevel {
                // 아래 레벨 라벨과 같은 높이를 위에 비워 두어 집 아이콘이 좌표에서 움직이지 않게 한다.
                Color.clear.frame(width: 1, height: MapHomePlacePinLayout.levelLabelHeight)
                homeGrowthCallout(level: growthLevel)
                    .opacity(isGrowthCalloutVisible ? 1 : 0)
                    .allowsHitTesting(isGrowthCalloutVisible)
                    .accessibilityHidden(!isGrowthCalloutVisible)
                Group {
                    if showsCatAtHome {
                        homeCatMarker(level: growthLevel)
                    } else {
                        homeMarkerArtwork(level: growthLevel)
                    }
                }
                .overlay(alignment: .top) {
                    if let weatherBadge {
                        homeWeatherBadge(weatherBadge)
                    }
                }
                homeLevelLabel(level: growthLevel)
            } else {
                MapHomeMarkerLabel(title: name, color: destination.tint)
                Image(systemName: destination.rpgSystemImage)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(destination.tint)
                    .frame(width: 48, height: 48)
                    .background(
                        Color.tpSurface.opacity(0.98),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.tpLine.opacity(0.95), lineWidth: 1)
                    }
                    .shadow(color: Color.tpInk.opacity(0.2), radius: 4, y: 2)
                Text("Lv.\(floor ?? 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.tpSurface.opacity(0.98), in: Capsule())
                    .overlay { Capsule().stroke(Color.tpLine, lineWidth: 0.8) }
                    .shadow(color: Color.tpInk.opacity(0.12), radius: 4, y: 2)
            }
        }
        .accessibilityElement(children: destination == .home ? .contain : .ignore)
        .accessibilityLabel(
            destination == .home
                ? "집 레벨 \(growthLevel ?? 1), \(growthStatus ?? "하루 요약 보기")"
                : "\(name), 레벨 \(floor ?? 1)"
        )
    }

    /// 집 아이콘 아래에 늘 보이는 레벨 라벨. 누르면 성장 카드와 오늘 하루 요약을 연다.
    /// 여는 동작이 없는 곳(Apple 지도의 주석 뷰)에서는 버튼으로 감싸지 않아 지도의 주석 선택이 그대로 일어난다.
    @ViewBuilder
    private func homeLevelLabel(level: Int) -> some View {
        let label = Text("Lv.\(level)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 12)
            .frame(height: MapHomePlacePinLayout.levelLabelHeight)
            .background(Color.tpSurface.opacity(0.98), in: Capsule())
            .overlay { Capsule().stroke(Color.tpLine, lineWidth: 0.8) }
            .shadow(color: Color.tpInk.opacity(0.12), radius: 4, y: 2)
            .contentShape(Capsule())
        if let onOpenDaySummary {
            Button(action: onOpenDaySummary) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("집 레벨 \(level) · 성장 카드와 오늘 하루 요약 열기")
                .accessibilityHint("하단에서 성장 카드와 오늘 하루 요약을 엽니다")
        } else {
            label
        }
    }

    /// 집 위에 얹는 현재 날씨(아이콘 + 기온). 집·화랑이 크기와 위치는 바꾸지 않는다.
    private func homeWeatherBadge(_ badge: MapHomeHomeWeatherBadge) -> some View {
        let palette = WeatherSymbolKind(symbolName: badge.symbolName).palette
        return HStack(spacing: 2) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color(red: palette.primary.red, green: palette.primary.green, blue: palette.primary.blue),
                    Color(red: palette.secondary.red, green: palette.secondary.green, blue: palette.secondary.blue)
                )
            Text(badge.temperatureText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.94), in: Capsule())
        .overlay { Capsule().stroke(Color.tpLine.opacity(0.8), lineWidth: 0.6) }
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
        .offset(y: -9)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppLanguagePreference.text(
                korean: "현재 날씨 \(badge.condition), \(badge.temperatureText)",
                english: "Current weather \(badge.condition), \(badge.temperatureText)"
            )
        )
    }

    private func homeMarkerArtwork(level: Int) -> some View {
        Image(MapHomeGrowthPolicy.artworkName(level: level))
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .background { homeMarkerBackground }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .simultaneousGesture(homeIconTapGesture(markerSize: CGSize(width: 48, height: 48)))
            .accessibilityElement()
            .accessibilityLabel("집 성장과 오늘 하루 요약 보기")
            .accessibilityHint("집 그림을 눌러 성장 카드와 오늘 하루 요약을 엽니다")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpenDaySummary?() }
            .overlay(alignment: .topTrailing) {
                if isLeapDay {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: "#E3B54A"))
                        .shadow(color: .white, radius: 1.5)
                        .offset(x: 2, y: -1)
                        .allowsHitTesting(false)
                }
            }
    }

    private var homeMarkerBackground: some View {
        Image(systemName: "hexagon.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.white.opacity(0.5))
            .frame(width: 56, height: 56)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func homeIconTapGesture(markerSize: CGSize) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { tap in
                guard MapHomeCatTapRouting.contains(
                    tapPoint: tap.location,
                    markerPoint: CGPoint(x: markerSize.width / 2, y: markerSize.height / 2),
                    radius: MapHomeCatTapRouting.homeIconHitRadius
                ) else { return }
                onOpenDaySummary?()
            }
    }

    private func toggleGrowthCallout() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isGrowthCalloutVisible.toggle()
        }
    }

    private func homeGrowthCallout(level: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Button {
                    onOpenDaySummary?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.tpAccent)
                        Text("Lv.\(level)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tpInk)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("집 레벨 \(level) · 오늘 하루 요약 열기")
                .accessibilityHint("하단에서 오늘 하루 요약을 엽니다")
                Spacer(minLength: 2)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isGrowthSummaryExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isGrowthSummaryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isGrowthSummaryExpanded ? "집 성장 요약 접기" : "집 성장 요약 펼치기")
            }
            Text(growthStatus ?? "")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(isGrowthQualifiedToday ? Color.tpAccent : Color.tpSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tpLine.opacity(0.55))
                    if isGrowthQualifiedToday {
                        Capsule()
                            .fill(Color.tpPastelMint)
                            .frame(width: proxy.size.width)
                    }
                }
            }
            .frame(height: 3)
            if isGrowthSummaryExpanded {
                HStack(spacing: 8) {
                    Label("연속 \(growthStreak)일", systemImage: "flame.fill")
                    Label("보상 \(pendingWeeklyRewards)", systemImage: "gift.fill")
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: isGrowthSummaryExpanded ? 150 : 126)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tpSurface.opacity(0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tpLine.opacity(0.9), lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.13), radius: 5, y: 2)
    }

    private func homeCatMarker(level: Int) -> some View {
        ZStack {
            Image(MapHomeGrowthPolicy.artworkName(level: level))
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
                .background { homeMarkerBackground }
            MapHomeStickmanGlyph(action: catAction, size: MapHomeStickmanMarker.size.width)
                .offset(
                    x: MapHomeCatTapRouting.catOffsetInHomeImage.x,
                    y: MapHomeCatTapRouting.catOffsetInHomeImage.y
                )
            if let accessory = MapHomeGrowthAccessoryCatalog.symbol(
                for: equippedAccessoryID
            ) {
                Image(systemName: accessory)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color(hex: "#D94772"))
                    .shadow(color: .white, radius: 1.5)
                    .offset(x: 25, y: -16)
            }
            if isLeapDay {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color(hex: "#E3B54A"))
                    .shadow(color: .white, radius: 1.5)
                    .offset(x: -20, y: -11)
            }
        }
        .frame(width: 78, height: 78)
        .contentShape(Rectangle())
        .simultaneousGesture(homeIconTapGesture(markerSize: CGSize(width: 78, height: 78)))
        .accessibilityElement()
        .accessibilityLabel("집 성장과 오늘 하루 요약 보기")
        .accessibilityHint("집 그림을 눌러 성장 카드와 오늘 하루 요약을 엽니다")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenDaySummary?() }
    }
}

private struct MapHomeTransitPlacePin: View {
    let name: String
    let kind: UserTransitLocationKind

    var body: some View {
        VStack(spacing: 4) {
            MapHomeMarkerLabel(title: name, color: Color.tpTransitDark)
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.tpTransitDark, in: Circle())
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
            MapHomeMarkerLabel(title: name, color: Color.tpTransitDark)
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.tpTransitDark, in: Circle())
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
        let xOffset = (0.5 - anchor.x)
        let yOffset = (0.5 - anchor.y)
        content
            .visualEffect { content, geometry in
                content.offset(
                    x: xOffset * geometry.size.width,
                    y: yOffset * geometry.size.height
                )
            }
            .position(
                x: point.x,
                y: point.y
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

    private let dotColor = Color(hex: "#E5352B")

    private var targetColor: Color {
        switch state {
        case .unavailable: Color.tpPastelGray
        case .locating: Color.tpPastelSky.opacity(0.55)
        case .available: Color.tpPastelSky
        case .following: Color.tpReferenceBlue
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: "scope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(targetColor)

            if state.showsTrackingDot {
                Circle()
                    .stroke(Color.tpReferenceBlue.opacity(0.5), lineWidth: 2)
                    .frame(width: 30, height: 30)
            }

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
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.tpSurface.opacity(0.98), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: Color.tpInk.opacity(0.13), radius: 5, y: 2)
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

private struct MapHomePredictedRouteMenu: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var saveFailed = false
    let model: AppModel
    let route: MapPredictedRoute
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("선택한 회색 경로", "Selected predicted route"))
                .font(.headline)
            Button { save(deleting: false) } label: {
                Label(language.text("변경", "Confirm"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            Button(role: .destructive) { save(deleting: true) } label: {
                Label(language.text("삭제", "Delete"), systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
            if saveFailed {
                Text(language.text("저장하지 못했습니다. 다시 시도해 주세요.", "Couldn’t save. Please try again."))
                    .font(.footnote).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .interactiveDismissDisabled(isSaving)
    }

    private func save(deleting: Bool) {
        isSaving = true
        saveFailed = false
        Task { @MainActor in
            if await model.savePredictedRouteDecision(route, deleting: deleting) { dismiss() }
            else { saveFailed = true }
            isSaving = false
        }
    }
}

private struct MapHomeTransitBoardingCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var isSaving = false
    @State private var saveFailed = false
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
                    .foregroundStyle(Color.tpTransitDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.tpTransitDark.opacity(0.12),
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
                isSaving = true
                saveFailed = false
                Task { @MainActor in
                    if await model.confirmTransitBoarding(candidate) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                    isSaving = false
                }
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
            .disabled(isSaving)

            Button(role: .destructive) {
                isSaving = true
                saveFailed = false
                Task { @MainActor in
                    if await model.deleteTransitBoardingCandidate(candidate) {
                        dismiss()
                    } else {
                        saveFailed = true
                    }
                    isSaving = false
                }
            } label: {
                Label(
                    language.text("이 후보 삭제", "Delete this candidate"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            if saveFailed {
                Text(language.text("저장하지 못했습니다. 다시 시도해 주세요.",
                    "Couldn’t save. Please try again."))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.tpSurface)
        .interactiveDismissDisabled(isSaving)
    }
}

private enum MapHomeStickerEditorTarget: Identifiable {
    case sticker(UUID)
    case memo(UUID)
    case newMemo(UUID)

    var id: String {
        switch self {
        case .sticker(let id): "sticker-\(id.uuidString)"
        case .memo(let id): "memo-\(id.uuidString)"
        case .newMemo(let id): "new-memo-\(id.uuidString)"
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
        .frame(
            minWidth: TaptionMenuMetrics.minimumHitSize,
            minHeight: TaptionMenuMetrics.minimumHitSize
        )
    }
}

private struct MapHomeMapMemoMarker: View {
    let memo: ActionMemo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .bold))
                Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
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
        .frame(
            minWidth: TaptionMenuMetrics.minimumHitSize,
            minHeight: TaptionMenuMetrics.minimumHitSize
        )
    }
}

private struct MapHomeStickerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let target: MapHomeStickerEditorTarget
    let language: MapHomeLanguage
    /// "위치 추가"를 누르면 편집 화면을 닫고 지도에서 핀을 고르게 한다. 메모 id를 넘긴다.
    var onRequestLocation: ((UUID) -> Void)? = nil

    @State private var title = ""
    @State private var memoText = ""
    @State private var hasTime = false
    @State private var keepsDraft = false
    @State private var memoKind: MemoKind = .idea
    @State private var placement: MapStickerPlacement = .map
    @State private var systemImage = "star.fill"
    @State private var colorHex = "#F28FA9"
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var occurredAt = Date()
    @State private var isDeleteConfirmationPresented = false
    @State private var didSave = false
    @State private var dictation = MapHomeDictation()
    @State private var dictationBase = ""

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

    private var isNewMemo: Bool {
        if case .newMemo = target { return true }
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
Group {

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
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
            .navigationTitle(
                language.text(
                    isSticker
                        ? "메모 스티커 수정"
                        : (isNewMemo ? "메모 추가" : "메모 수정"),
                    isSticker
                        ? "Edit memo sticker"
                        : (isNewMemo ? "Add memo" : "Edit memo")
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("취소", "Cancel")) { cancel() }
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
            .onDisappear {
                if isNewMemo, !didSave, !keepsDraft {
                    deleteNewMemoIfNeeded()
                }
            }
        }
    }

    @ViewBuilder
    private var stickerFields: some View {
        Section(language.text("메모 스티커", "Memo sticker")) {
            TextField(language.text("제목", "Title"), text: $title)
            memoInputField(prompt: nil)
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

    /// 메모 입력칸과 마이크 버튼. 마이크를 누르면 말한 내용이 메모 끝에 글자로 이어진다.
    private func memoInputField(prompt: Text?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let prompt {
                        TextField(language.text("메모 내용", "Memo text"), text: $memoText, prompt: prompt, axis: .vertical)
                    } else {
                        TextField(language.text("메모 내용", "Memo text"), text: $memoText, axis: .vertical)
                    }
                }
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(dictation.isListening ? Color.tpHoliday : Color.tpAccent)
                        .frame(width: 34, height: 34)
                        .background(Color.tpAccent.opacity(0.10), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(language.text(dictation.isListening ? "음성 입력 중지" : "음성으로 입력", dictation.isListening ? "Stop dictation" : "Dictate"))
            }
            if let message = dictation.errorMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tpHoliday)
            }
        }
        .onChange(of: dictation.transcript) { _, text in
            if dictation.isListening || !text.isEmpty { memoText = dictationBase + text }
        }
        .onDisappear { dictation.stop() }
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
        } else {
            dictationBase = memoText.isEmpty ? "" : memoText + " "
            let identifier = language == .korean ? "ko-KR" : "en-US"
            Task { await dictation.start(localeIdentifier: identifier) }
        }
    }

    @ViewBuilder
    private var memoFields: some View {
        Section(language.text("메모", "Memo")) {
            memoInputField(prompt: Text(language.text("새 메모", "New memo")))
        }
        Section {
            Toggle(language.text("시간 지정", "Set a time"), isOn: $hasTime)
            if hasTime {
                DatePicker(
                    language.text("시간", "Time"),
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        } header: {
            Text(language.text("시간", "Time"))
        } footer: {
            Text(language.text(
                "시간을 지정하지 않으면 왼쪽 위 메모 목록에 쌓여요.",
                "Memos without a time stack in the list at the top left."
            ))
        }
        Section {
            if let point = editedPoint {
                Label(
                    String(format: "%.5f, %.5f", point.latitude, point.longitude),
                    systemImage: "mappin.circle.fill"
                )
                Button(language.text("위치 다시 고르기", "Choose again")) { requestLocation() }
                Button(language.text("위치 지우기", "Remove location"), role: .destructive) {
                    latitudeText = ""
                    longitudeText = ""
                }
            } else {
                Button {
                    requestLocation()
                } label: {
                    Label(language.text("위치 추가", "Add location"), systemImage: "mappin.and.ellipse")
                }
            }
        } header: {
            Text(language.text("위치", "Location"))
        } footer: {
            Text(language.text(
                "위치를 넣으면 지도에 핀으로 보이고, 없으면 시간에 따른 메모로 보여요.",
                "With a location the memo shows as a map pin; without one it follows the time."
            ))
        }
    }

    /// 위치 고르기: 지금까지 쓴 내용을 임시로 남기고 편집 화면을 닫는다. 핀을 고르면 다시 열린다.
    private func requestLocation() {
        switch target {
        case .newMemo(let id):
            keepsDraft = true
            model.updateMemoDraft(
                id,
                text: memoText,
                occurredAt: occurredAt,
                isTimeless: !hasTime,
                mapPoint: .some(editedPoint)
            )
            dismiss()
            onRequestLocation?(id)
        case .memo(let id):
            keepsDraft = true
            if !memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = model.updateMapMemo(
                    id,
                    text: memoText,
                    kind: memoKind,
                    mapPoint: editedPoint,
                    occurredAt: occurredAt,
                    isTimeless: !hasTime
                )
            }
            dismiss()
            onRequestLocation?(id)
        case .sticker:
            break
        }
    }

    private var coordinateFields: some View {
        Group {
            TextField(language.text("위도", "Latitude"), text: $latitudeText)
                .keyboardType(.decimalPad)
            TextField(language.text("경도", "Longitude"), text: $longitudeText)
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
        case .memo(let id), .newMemo(let id):
            guard let memo = model.snapshot.memos.first(where: { $0.id == id }) else { return }
            // 임시로 넣어 둔 문구는 빈칸으로 두고, 위치를 고르고 돌아온 초안은 쓴 글을 그대로 보여 준다.
            let placeholders = ["새 메모", "New memo", "새 지도 메모", "New map memo"]
            memoText = (isNewMemo && placeholders.contains(memo.text)) ? "" : memo.text
            memoKind = memo.kind
            occurredAt = memo.occurredAt
            hasTime = memo.isTimeless != true
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
        case .memo(let id), .newMemo(let id):
            guard model.updateMapMemo(
                id,
                text: memoText,
                kind: memoKind,
                mapPoint: editedPoint,
                occurredAt: occurredAt,
                isTimeless: !hasTime
            ) else { return }
            didSave = true
        }
        dismiss()
    }

    private func cancel() {
        didSave = true
        deleteNewMemoIfNeeded()
        dismiss()
    }

    private func deleteNewMemoIfNeeded() {
        guard case .newMemo(let id) = target else { return }
        model.discardMapMemoDraft(id)
    }

    private func delete() {
        didSave = true
        switch target {
        case .sticker(let id): model.deleteMapSticker(id)
        case .memo(let id): model.deleteMemo(id)
        case .newMemo(let id): model.discardMapMemoDraft(id)
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
        case .direct:
            [.direct]
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
    case direct

    init(mode: TravelMode) {
        switch mode {
        case .car, .taxi:
            self = .automobile
        case .subway, .train, .bus:
            self = .transit
        case .walking, .running, .cycling:
            self = .walking
        case .airplane, .ship:
            self = .direct
        }
    }

    var forecastColorHex: String {
        switch self {
        case .transit: MapHomeWBSTripStyle.transitRouteHex
        default: MapHomeWBSTripStyle.forecastRouteHex
        }
    }

}

private struct MapHomeAppleRoute {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let geometrySignature: Int
    let colorHex: String
    let opacity: Double
    let phase: MapHomeAppleRoutePhase
    let transport: MapHomeAppleRouteTransport?
}

private enum MapHomeAppleAnnotationKind {
    case temporary(stationName: String, title: String)
    case place(MapHomePlaceAnnotation)
    case transit(MapHomeTransitAnnotation)
    case boarding(TransitBoardingCandidate)
    case sticker(MapSticker)
    case memo(ActionMemo)
    case search(MapHomeSearchResult)
    case pawprint(MapHomeApplePawprint)
}

/// Apple 지도에 그릴 발자국 하나. 벡터 지도의 `PawprintWaypoint`와 같은 정보를 값으로 옮긴 것이다.
private struct MapHomeApplePawprint: Equatable {
    let index: Int
    let angle: Double
    let isPredicted: Bool
    let isSelectedRoute: Bool
    let speedMetersPerSecond: Double?
}

private struct MapHomeAppleAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: MapHomeAppleAnnotationKind
    let accessibilityLabel: String
    let isInteractive: Bool
}

private struct MapHomeApplePlayback {
    let coordinate: CLLocationCoordinate2D
    let cameraCoordinate: CLLocationCoordinate2D
    let headingDegrees: CLLocationDirection
    let action: MapHomeStickmanAction
    let accessibilityLabel: String
    let phase: MapHomeAppleRoutePhase
    let followsUserLocation: Bool
    let equippedAccessoryID: String?
    let stickmanAnimationPhase: Int?
}

struct MapHomeAppleViewportCommand {
    let revision: Int
    let centerCoordinate: CLLocationCoordinate2D?
    let heading: CLLocationDirection?
    let targetPoint: CGPoint?
    /// 실시간 자동 줌이 정한 카메라 거리(없으면 현재 거리 유지).
    var distance: CLLocationDistance? = nil
}

enum MapHomeAppleCameraCommand {
    @MainActor
    static func center(
        _ coordinate: CLLocationCoordinate2D,
        at targetPoint: CGPoint?,
        distance: CLLocationDistance? = nil,
        on mapView: MKMapView
    ) {
        if let distance, distance.isFinite, distance > 0 {
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = distance
            mapView.setCamera(camera, animated: false)
        }
        mapView.setCenter(
            cameraCenter(
                for: coordinate,
                at: targetPoint,
                on: mapView
            ),
            animated: false
        )
    }

    @MainActor
    static func heading(
        _ heading: CLLocationDirection,
        centeredAt coordinate: CLLocationCoordinate2D?,
        targetPoint: CGPoint?,
        distance requestedDistance: CLLocationDistance? = nil,
        on mapView: MKMapView
    ) {
        let camera = mapView.camera.copy() as! MKMapCamera
        let distance = requestedDistance.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? camera.centerCoordinateDistance
        let pitch = camera.pitch
        if let coordinate {
            camera.centerCoordinate = coordinate
        }
        camera.heading = heading
        camera.centerCoordinateDistance = distance
        camera.pitch = pitch
        mapView.setCamera(camera, animated: false)
        if let coordinate {
            center(coordinate, at: targetPoint, on: mapView)
        }
    }

    @MainActor
    private static func cameraCenter(
        for coordinate: CLLocationCoordinate2D,
        at targetPoint: CGPoint?,
        on mapView: MKMapView
    ) -> CLLocationCoordinate2D {
        guard let targetPoint,
              mapView.bounds.width > 0,
              mapView.bounds.height > 0 else { return coordinate }
        let locationPoint = mapView.convert(coordinate, toPointTo: mapView)
        let sourcePoint = MapHomeCameraLayoutMath.cameraCenterSourcePoint(
            currentLocationPoint: locationPoint,
            targetPoint: targetPoint,
            viewportSize: mapView.bounds.size
        )
        return mapView.convert(sourcePoint, toCoordinateFrom: mapView)
    }
}

enum MapHomeApplePlaybackMath {
    private static let directionStep: CLLocationDirection = 45
    private static let lookAheadProgress = 0.01

    static func heading(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double]? = nil
    ) -> CLLocationDirection {
        guard coordinates.count >= 2 else { return 0 }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        let progress = duration > 0
            ? min(max(date.timeIntervalSince(departureDate) / duration, 0), 1)
            : 1
        guard let currentCoordinate = MapHomeExpectedRoutePlaybackMath.coordinate(
            atProgress: progress,
            coordinates: coordinates,
            segmentLengths: segmentLengths
        ), let lookAhead = MapHomeExpectedRoutePlaybackMath.coordinate(
            atProgress: min(1, progress + lookAheadProgress),
            coordinates: coordinates,
            segmentLengths: segmentLengths
        ) else { return 0 }
        if !sameLocation(currentCoordinate, lookAhead) {
            return stableHeading(bearing(from: currentCoordinate, to: lookAhead))
        }
        let lookBehind = MapHomeExpectedRoutePlaybackMath.coordinate(
            atProgress: max(0, progress - lookAheadProgress),
            coordinates: coordinates,
            segmentLengths: segmentLengths
        ) ?? currentCoordinate
        return stableHeading(bearing(from: lookBehind, to: currentCoordinate))
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
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      let point = reading.point,
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
                bearing(from: before.1, to: after.1)
            )
        }
        return stableHeading(
            bearing(
                from: points[points.count - 2].1,
                to: points[points.count - 1].1
            )
        )
    }

    private static func sameLocation(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        lhs.latitude == rhs.latitude
            && RouteTimelineLongitude.shortestDelta(
                from: lhs.longitude,
                to: rhs.longitude
            ) == 0
    }

    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let adjustedEnd = CLLocationCoordinate2D(
            latitude: end.latitude,
            longitude: start.longitude + RouteTimelineLongitude.shortestDelta(
                from: start.longitude,
                to: end.longitude
            )
        )
        return MapHomeVectorNavigationMath.bearing(from: start, to: adjustedEnd)
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
    var label: String
    var isInteractive: Bool
    dynamic var coordinate: CLLocationCoordinate2D

    init(annotation: MapHomeAppleAnnotation) {
        identifier = annotation.id
        kind = annotation.kind
        label = annotation.accessibilityLabel
        isInteractive = annotation.isInteractive
        coordinate = annotation.coordinate
        super.init()
    }

    var title: String? {
        label
    }

    func update(from annotation: MapHomeAppleAnnotation) {
        kind = annotation.kind
        label = annotation.accessibilityLabel
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
    var speedMetersPerSecond: Double?
    var equippedAccessoryID: String?

    init(playback: MapHomeApplePlayback) {
        coordinate = playback.coordinate
        headingDegrees = playback.headingDegrees
        action = playback.action
        label = playback.accessibilityLabel
        phase = playback.phase
        stickmanAnimationPhase = playback.stickmanAnimationPhase
        equippedAccessoryID = playback.equippedAccessoryID
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
        equippedAccessoryID = playback.equippedAccessoryID
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

/// 발자국 주석. SwiftUI 호스팅 뷰를 수백 개 만들면 늦게 뜨고 첫 배치 때 위치가 어긋나므로 이미지 뷰 하나만 쓴다.
private final class MapHomeApplePawprintAnnotationView: MKAnnotationView {
    private static let size = CGSize(width: 28, height: 28)
    private static var imageCache: [UInt32: UIImage] = [:]
    private let imageView = UIImageView()
    private var appliedColor: UInt32?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(origin: .zero, size: Self.size)
        imageView.frame = bounds
        imageView.contentMode = .center
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        centerOffset = .zero
        canShowCallout = false
        clipsToBounds = false
        displayPriority = .defaultLow
        collisionMode = .none
        zPriority = .min
        selectedZPriority = .min
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ paw: MapHomeApplePawprint, color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        let key = (byte(red) << 24) | (byte(green) << 16) | (byte(blue) << 8) | byte(alpha)
        if appliedColor != key {
            appliedColor = key
            if let cached = Self.imageCache[key] {
                imageView.image = cached
            } else {
                let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                let image = UIImage(systemName: "pawprint.fill", withConfiguration: configuration)?
                    .withTintColor(color, renderingMode: .alwaysOriginal)
                if Self.imageCache.count > 64 { Self.imageCache.removeAll() }
                Self.imageCache[key] = image
                imageView.image = image
            }
        }
        transform = CGAffineTransform(rotationAngle: CGFloat(paw.angle * .pi / 180))
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
        let departureBucket: Int?
    }

    private let cacheCapacity = 128
    private var cache: [CacheKey: [CLLocationCoordinate2D]] = [:]
    private var cacheRecency: [CacheKey] = []

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
            transport: transport,
            departureBucket: transport == .transit
                ? Int(departureDate.timeIntervalSince1970 / (15 * 60))
                : nil
        )
        if let cached = cache[key] {
            touch(key)
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
                insert(coordinates, for: key)
                return coordinates
            }
        }
        return nil
    }

    private func insert(
        _ coordinates: [CLLocationCoordinate2D],
        for key: CacheKey
    ) {
        cache[key] = coordinates
        touch(key)
        while cacheRecency.count > cacheCapacity,
              let oldest = cacheRecency.first {
            cacheRecency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: CacheKey) {
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
    }

    private func calculate(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        transport: ExpectedRouteTransport,
        departureDate: Date
    ) async -> [CLLocationCoordinate2D]? {
        if transport == .direct {
            return [start, end]
        }
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
        case .direct: .walking
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

/// Apple 지도용 안개 탐험. 벡터 지도의 `fogOfWarOverlay`와 같은 모양(어둡게 덮고
/// 발자국·장소 61pt, 현재 위치 81pt 반경만 둥글게 걷어냄)을 MapKit 오버레이로 그린다.
private struct MapHomeFogReveal: Equatable {
    let coordinate: CLLocationCoordinate2D
    let radius: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.radius == rhs.radius
    }
}

private final class MapHomeFogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let reveals: [(point: MKMapPoint, radius: CGFloat)]

    init(reveals: [MapHomeFogReveal]) {
        self.reveals = reveals.map { (MKMapPoint($0.coordinate), $0.radius) }
    }
}

private final class MapHomeFogRenderer: MKOverlayRenderer {
    private nonisolated(unsafe) static let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [UIColor.black.cgColor,
                 UIColor.black.withAlphaComponent(0.7).cgColor,
                 UIColor.clear.cgColor] as CFArray,
        locations: [0, 0.5, 1]
    )

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fog = overlay as? MapHomeFogOverlay else { return }
        let tile = rect(for: mapRect)
        context.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        context.fill(tile)
        guard let gradient = Self.gradient else { return }
        context.setBlendMode(.destinationOut)
        for reveal in fog.reveals {
            let center = point(for: reveal.point)
            // Radius is in screen points; renderer space is map points scaled by zoomScale.
            let radius = reveal.radius / zoomScale
            let circle = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
            guard circle.intersects(tile) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius, options: [])
        }
    }
}

private struct MapHomeAppleMap: UIViewRepresentable {
    let style: MapDisplayStyle
    let accessibilityLabel: String
    let cameraPosition: MapCameraPosition
    let cameraRevision: Int
    let viewportCommand: MapHomeAppleViewportCommand?
    let routes: [MapHomeAppleRoute]
    let annotations: [MapHomeAppleAnnotation]
    let playback: MapHomeApplePlayback?
    let centersPlayback: Bool
    let playbackTargetPoint: CGPoint
    let contentInsets: UIEdgeInsets
    let longPressExclusionFrame: CGRect
    /// nil = 안개 탐험 꺼짐.
    let fogReveals: [MapHomeFogReveal]?
    let onCameraFrame: (MapHomeCameraFrame, CGPoint?, Bool) -> Void
    let onSingleFingerPanBegan: () -> Void
    let onUserCameraGesture: () -> Void
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
        mapView.accessibilityLabel = accessibilityLabel
        context.coordinator.attach(to: mapView)
        context.coordinator.applyMapStyle(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isApplyingSwiftUIUpdate = true
        defer { context.coordinator.isApplyingSwiftUIUpdate = false }
        if mapView.layoutMargins != contentInsets {
            mapView.layoutMargins = contentInsets
        }
        if mapView.accessibilityLabel != accessibilityLabel {
            mapView.accessibilityLabel = accessibilityLabel
        }
        context.coordinator.refreshGestureAttachments(in: mapView)
        context.coordinator.applyMapStyle(to: mapView)
        context.coordinator.updateContent(in: mapView)
        context.coordinator.applyCameraCommandIfNeeded(to: mapView)
        context.coordinator.applyViewportCommandIfNeeded(to: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapHomeAppleMap
        private weak var mapView: MKMapView?
        private var lastCameraRevision = Int.min
        private var lastViewportCommandRevision = 0
        private var lastRoutesSignature = ""
        private var lastMapStyleRawValue: String?
        private var lastAnnotationsSignature = ""
        private var lastPlaybackSignature: String?
        private var lastCentersPlayback: Bool?
        private var lastCenteredPlaybackCoordinate: CLLocationCoordinate2D?
        private var lastCenteredPlaybackTargetPoint: CGPoint?
        private var routeStyles: [ObjectIdentifier: MapHomeAppleRouteStyle] = [:]
        private var routePolylines: [String: MKPolyline] = [:]
        private var fogOverlay: MapHomeFogOverlay?
        private var lastFogReveals: [MapHomeFogReveal]?
        private var routeSignatures: [String: String] = [:]
        private var walkerAnnotation: MapHomeAppleWalkerAnnotation?
        private var walkerView: MapHomeAppleHostedAnnotationView?
        private var observedPanGestures: [UIPanGestureRecognizer] = []
        private var observedCameraGestures: [UIGestureRecognizer] = []
        private var lastGestureAttachmentScanUptime = -Double.infinity
        private var longPressGesture: UILongPressGestureRecognizer?
        fileprivate var isApplyingSwiftUIUpdate = false
        private var cameraFramePublishPending = false
        private var cameraFramePublishIsFinal = false
        private var lastCameraPublishUptime = -Double.infinity

        init(parent: MapHomeAppleMap) {
            self.parent = parent
        }

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            refreshGestureAttachments(in: mapView, force: true)

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
            longPressGesture = longPress
        }

        func detach(from mapView: MKMapView) {
            walkerView?.removeFromSuperview()
            walkerView = nil
            for gesture in observedPanGestures {
                gesture.removeTarget(self, action: #selector(handlePan(_:)))
            }
            observedPanGestures.removeAll()
            for gesture in observedCameraGestures {
                gesture.removeTarget(self, action: #selector(handleCameraGesture(_:)))
            }
            observedCameraGestures.removeAll()
            if let longPressGesture {
                mapView.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            lastGestureAttachmentScanUptime = -Double.infinity
            cameraFramePublishIsFinal = false
            lastCameraPublishUptime = -Double.infinity
            self.mapView = nil
        }

        func refreshGestureAttachments(
            in mapView: MKMapView,
            force: Bool = false
        ) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastGestureAttachmentScanUptime >= 1 else {
                return
            }
            lastGestureAttachmentScanUptime = now
            attachPanGestures(in: mapView)
            attachCameraGestures(in: mapView)
        }

        func attachPanGestures(in view: UIView) {
            let gestures = allSubviews(in: view).flatMap { $0.gestureRecognizers ?? [] }
                .compactMap { $0 as? UIPanGestureRecognizer }
            let currentIDs = Set(gestures.map { ObjectIdentifier($0) })
            for gesture in observedPanGestures
            where !currentIDs.contains(ObjectIdentifier(gesture)) {
                gesture.removeTarget(self, action: #selector(handlePan(_:)))
            }
            observedPanGestures.removeAll {
                !currentIDs.contains(ObjectIdentifier($0))
            }
            let observedIDs = Set(observedPanGestures.map { ObjectIdentifier($0) })
            for gesture in gestures where !observedIDs.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(handlePan(_:)))
                observedPanGestures.append(gesture)
            }
        }

        func applyMapStyle(to mapView: MKMapView) {
            let style = parent.style.runtimeStyle
            guard lastMapStyleRawValue != style.rawValue else { return }
            lastMapStyleRawValue = style.rawValue
            mapView.overrideUserInterfaceStyle = .light
            mapView.clipsToBounds = true
            mapView.layer.masksToBounds = true
            mapView.pointOfInterestFilter = .excludingAll
            mapView.showsTraffic = false
            switch style {
            case .imagery:
                // 위성: 항공 사진만. 이전에는 선택과 무관하게 흐린 표준 지도로 고정돼 있었다.
                mapView.mapType = .satellite
                mapView.backgroundColor = .black
                mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .hybrid:
                // 하이브리드: 항공 사진 위에 도로·지명.
                mapView.mapType = .hybrid
                mapView.backgroundColor = .black
                let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            case .standard:
                mapView.mapType = .standard
                mapView.backgroundColor = UIColor(hex: MapHomeWBSTripStyle.paperHex)
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .default
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            default:
                // 간략화(그리고 벡터 스타일의 Apple 대체): 기존의 흐린(muted) 표준 지도.
                mapView.mapType = .mutedStandard
                mapView.backgroundColor = UIColor(hex: MapHomeWBSTripStyle.paperHex)
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .muted
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            }
        }

        func updateContent(in mapView: MKMapView) {
            updateFog(in: mapView)
            updateRoutes(in: mapView)
            updateAnnotations(in: mapView)
            updateWalker(in: mapView)
            updateWalkerPosition(in: mapView)
        }

        func applyCameraCommandIfNeeded(to mapView: MKMapView) {
            guard lastCameraRevision != parent.cameraRevision else { return }
            lastCameraRevision = parent.cameraRevision
            if let revision = parent.viewportCommand?.revision,
               revision != lastViewportCommandRevision {
                return
            }

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
            publishCameraFrameAfterUpdate(from: mapView, isFinal: true)
        }

        func applyViewportCommandIfNeeded(to mapView: MKMapView) {
            guard let command = parent.viewportCommand,
                  command.revision != lastViewportCommandRevision else { return }
            lastViewportCommandRevision = command.revision
            if let heading = command.heading {
                MapHomeAppleCameraCommand.heading(
                    heading,
                    centeredAt: command.centerCoordinate,
                    targetPoint: command.targetPoint,
                    distance: command.distance,
                    on: mapView
                )
            } else if let coordinate = command.centerCoordinate {
                MapHomeAppleCameraCommand.center(
                    coordinate,
                    at: command.targetPoint,
                    distance: command.distance,
                    on: mapView
                )
            }
            publishCameraFrameAfterUpdate(from: mapView, isFinal: true)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            publishCameraFrame(from: mapView, isFinal: false)
        }

        func mapView(_: MKMapView, regionWillChangeAnimated _: Bool) {
            // Pan/pinch callbacks are observed directly. Walking every MapKit
            // subview here competes with the gesture's first camera frames.
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateWalkerPosition(in: mapView)
            publishCameraFrame(from: mapView, isFinal: true)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            normalizeAnnotationLayerOrder(of: views, in: mapView)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            updateWalker(in: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let reuseIdentifier = "MapHome.hiddenUserLocation"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: reuseIdentifier
                ) ?? MKAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: reuseIdentifier
                )
                view.annotation = annotation
                view.isHidden = true
                view.isAccessibilityElement = false
                view.canShowCallout = false
                return view
            }
            guard let annotation = annotation as? MapHomeAppleMapAnnotation else {
                return nil
            }
            if case .pawprint = annotation.kind {
                let pawIdentifier = "MapHome.applePawprint"
                let pawView = (mapView.dequeueReusableAnnotationView(withIdentifier: pawIdentifier)
                    as? MapHomeApplePawprintAnnotationView)
                    ?? MapHomeApplePawprintAnnotationView(annotation: annotation, reuseIdentifier: pawIdentifier)
                configurePawprint(pawView, annotation: annotation)
                return pawView
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
            updateWalkerPosition(in: mapView)
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {
            if let fog = overlay as? MapHomeFogOverlay {
                return MapHomeFogRenderer(overlay: fog)
            }
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
                guard !MapHomeLongPressRoutingMath.isAnnotationTouch(touch.view) else {
                    return false
                }
                guard let view = gestureRecognizer.view else { return true }
                return MapHomeLongPressRoutingMath.shouldPresentLocation(
                    at: touch.location(in: view),
                    excluding: parent.longPressExclusionFrame
                )
            }
            return !MapHomeLongPressRoutingMath.isAnnotationTouch(touch.view)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.numberOfTouches <= 1 else { return }
            switch gesture.state {
            case .began:
                parent.onSingleFingerPanBegan()
            case .ended, .cancelled, .failed:
                break
            default:
                break
            }
        }

        @objc private func handleCameraGesture(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onUserCameraGesture()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  gesture.numberOfTouches <= 1,
                  let mapView else { return }
            parent.onLongPress(
                mapView.convert(
                    gesture.location(in: mapView),
                    toCoordinateFrom: mapView
                )
            )
        }

        private func updateRoutes(in mapView: MKMapView) {
            let routeSignatures = Dictionary(
                parent.routes.map { route in
                    (route.id, [
                    route.id,
                    route.phase == .actual ? "actual" : "forecast",
                    String(route.geometrySignature),
                    route.colorHex,
                    String(route.opacity),
                    ].joined(separator: "|"))
                },
                uniquingKeysWith: { first, _ in first }
            )
            let signature = parent.routes.compactMap {
                routeSignatures[$0.id]
            }.joined(separator: ";")
            guard signature != lastRoutesSignature else { return }
            lastRoutesSignature = signature
            let staleIDs = Set(self.routePolylines.keys).filter {
                routeSignatures[$0] != self.routeSignatures[$0]
            }
            let removed = staleIDs.compactMap {
                self.routePolylines.removeValue(forKey: $0)
            }
            for polyline in removed {
                routeStyles.removeValue(forKey: ObjectIdentifier(polyline))
            }
            if !removed.isEmpty {
                mapView.removeOverlays(removed)
            }
            for id in staleIDs {
                self.routeSignatures.removeValue(forKey: id)
            }
            let polylines = parent.routes.compactMap { route -> MKPolyline? in
                guard self.routePolylines[route.id] == nil else { return nil }
                guard route.coordinates.count >= 2 else { return nil }
                var coordinates = route.coordinates
                let polyline = MKPolyline(
                    coordinates: &coordinates,
                    count: coordinates.count
                )
                self.routePolylines[route.id] = polyline
                self.routeSignatures[route.id] = routeSignatures[route.id]
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

        private func updateFog(in mapView: MKMapView) {
            guard parent.fogReveals != lastFogReveals else { return }
            lastFogReveals = parent.fogReveals
            if let fogOverlay { mapView.removeOverlay(fogOverlay) }
            fogOverlay = nil
            guard let reveals = parent.fogReveals else { return }
            let overlay = MapHomeFogOverlay(reveals: reveals)
            fogOverlay = overlay
            // Index 0 keeps the fog under the route polylines, like the vector map.
            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
        }

        private func updateAnnotations(in mapView: MKMapView) {
            let signature = parent.annotations.map { annotation in
                [
                    annotation.id,
                    String(annotation.coordinate.latitude),
                    String(annotation.coordinate.longitude),
                    String(annotation.isInteractive),
                    annotation.accessibilityLabel,
                    String(describing: annotation.kind),
                ].joined(separator: "|")
            }.joined(separator: ";")
            guard signature != lastAnnotationsSignature else { return }
            lastAnnotationsSignature = signature
            let existing = mapView.annotations.compactMap { $0 as? MapHomeAppleMapAnnotation }
            let byID = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
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
                    } else if let view = mapView.view(for: existing) as? MapHomeApplePawprintAnnotationView {
                        configurePawprint(view, annotation: existing)
                    }
                } else {
                    mapView.addAnnotation(MapHomeAppleMapAnnotation(annotation: annotation))
                }
            }
        }

        private func updateWalker(in mapView: MKMapView) {
            let playback = parent.playback
            let playbackSignature: String? = playback.map { playback in
                let parts: [String] = [
                    String(playback.coordinate.latitude),
                    String(playback.coordinate.longitude),
                    String(playback.cameraCoordinate.latitude),
                    String(playback.cameraCoordinate.longitude),
                    String(playback.headingDegrees),
                    String(describing: playback.action),
                    playback.accessibilityLabel,
                    String(describing: playback.phase),
                    String(playback.followsUserLocation),
                    String(describing: playback.stickmanAnimationPhase),
                    String(describing: parent.playbackTargetPoint.x),
                    String(describing: parent.playbackTargetPoint.y),
                ]
                return parts.joined(separator: "|")
            }
            guard playbackSignature != lastPlaybackSignature
                    || parent.centersPlayback != lastCentersPlayback else {
                return
            }
            lastPlaybackSignature = playbackSignature
            lastCentersPlayback = parent.centersPlayback
            guard let playback else {
                walkerView?.removeFromSuperview()
                walkerView = nil
                walkerAnnotation = nil
                lastCenteredPlaybackCoordinate = nil
                lastCenteredPlaybackTargetPoint = nil
                return
            }
            let walker: MapHomeAppleWalkerAnnotation
            if let walkerAnnotation {
                walker = walkerAnnotation
                walker.update(with: playback)
            } else {
                walker = MapHomeAppleWalkerAnnotation(playback: playback)
                walkerAnnotation = walker
            }
            let view: MapHomeAppleHostedAnnotationView
            if let walkerView {
                view = walkerView
            } else {
                view = MapHomeAppleHostedAnnotationView(annotation: nil, reuseIdentifier: nil)
                walkerView = view
            }
            configureWalker(view, annotation: walker)
            updateWalkerPosition(in: mapView)
            if !parent.centersPlayback {
                lastCenteredPlaybackCoordinate = nil
                lastCenteredPlaybackTargetPoint = nil
            } else if MapHomePlaybackCenterPolicy.shouldCenter(
                previousCoordinate: lastCenteredPlaybackCoordinate,
                previousTargetPoint: lastCenteredPlaybackTargetPoint,
                coordinate: playback.cameraCoordinate,
                targetPoint: parent.playbackTargetPoint,
                hasPendingViewportCommand: parent.viewportCommand.map {
                    $0.revision != lastViewportCommandRevision
                } ?? false
            ) {
                lastCenteredPlaybackCoordinate = playback.cameraCoordinate
                lastCenteredPlaybackTargetPoint = parent.playbackTargetPoint
                MapHomeAppleCameraCommand.center(
                    playback.cameraCoordinate,
                    at: parent.playbackTargetPoint,
                    on: mapView
                )
            }
        }

        func attachCameraGestures(in view: UIView) {
            let gestures = allSubviews(in: view).flatMap { $0.gestureRecognizers ?? [] }
                .filter { $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer }
            let currentIDs = Set(gestures.map { ObjectIdentifier($0) })
            for gesture in observedCameraGestures
            where !currentIDs.contains(ObjectIdentifier(gesture)) {
                gesture.removeTarget(self, action: #selector(handleCameraGesture(_:)))
            }
            observedCameraGestures.removeAll {
                !currentIDs.contains(ObjectIdentifier($0))
            }
            let observedIDs = Set(observedCameraGestures.map { ObjectIdentifier($0) })
            for gesture in gestures where !observedIDs.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(handleCameraGesture(_:)))
                observedCameraGestures.append(gesture)
            }
        }

        private func allSubviews(in view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(allSubviews)
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
                            : .actual,
                        speedMetersPerSecond: annotation.speedMetersPerSecond,
                        equippedAccessoryID: annotation.equippedAccessoryID
                    )
                ),
                size: MapHomeStickmanMarker.size,
                centerOffset: MapHomeStickmanAnnotationLayout.centerOffset
            )
            UIView.performWithoutAnimation {
                view.transform = .identity
            }
            view.displayPriority = .required
            view.collisionMode = .none
            view.zPriority = .max
            view.selectedZPriority = .max
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.stickman
            view.superview?.bringSubviewToFront(view)
            view.isEnabled = false
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityTraits = .image
            view.accessibilityLabel = annotation.label
        }

        private func configurePawprint(
            _ view: MapHomeApplePawprintAnnotationView,
            annotation: MapHomeAppleMapAnnotation
        ) {
            guard case .pawprint(let paw) = annotation.kind else { return }
            let color: Color = paw.isSelectedRoute ? .orange
                : paw.isPredicted ? Color.gray.opacity(0.68)
                : MapHomePawprintSpeedColor.color(forMetersPerSecond: paw.speedMetersPerSecond)
            view.annotation = annotation
            view.apply(paw, color: UIColor(color))
            view.isEnabled = annotation.isInteractive
            view.isUserInteractionEnabled = annotation.isInteractive
            view.isAccessibilityElement = annotation.isInteractive
            view.accessibilityTraits = annotation.isInteractive ? .button : .image
            view.accessibilityIdentifier = "MapHome.appleAnnotation.\(annotation.identifier)"
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
            if case .pawprint = annotation.kind {
                // 발자국은 수백 개라서 충돌 계산에 넣으면 집·회사 같은 핀이 가려진다. 충돌에서 빼고 핀 아래에 둔다.
                view.displayPriority = .defaultLow
                view.collisionMode = .none
                view.zPriority = .min
                view.selectedZPriority = .min
            } else {
                view.displayPriority = .defaultHigh
                view.collisionMode = .rectangle
                view.zPriority = .defaultUnselected
                view.selectedZPriority = .defaultUnselected
            }
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.place
            view.isEnabled = annotation.isInteractive
            view.isUserInteractionEnabled = annotation.isInteractive
            view.isAccessibilityElement = true
            view.accessibilityTraits = annotation.isInteractive ? .button : .image
            view.accessibilityIdentifier = "MapHome.appleAnnotation.\(annotation.identifier)"
            view.accessibilityLabel = annotation.label
        }

        /// didAdd는 배치로 불리므로 새로 붙은 뷰만 정리한다(전체 순회는 발자국이 많을 때 O(N²)).
        private func normalizeAnnotationLayerOrder(of views: [MKAnnotationView], in mapView: MKMapView) {
            for view in views {
                guard let annotation = view.annotation else { continue }
                if annotation is MKUserLocation {
                    view.zPriority = .min
                    view.selectedZPriority = .min
                    view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.userLocation
                } else if let hosted = annotation as? MapHomeAppleMapAnnotation {
                    let isPawprint: Bool
                    if case .pawprint = hosted.kind { isPawprint = true } else { isPawprint = false }
                    view.zPriority = isPawprint ? .min : .defaultUnselected
                    view.selectedZPriority = isPawprint ? .min : .defaultUnselected
                    view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.place
                }
            }
            updateWalkerPosition(in: mapView)
        }

        private func updateWalkerPosition(in mapView: MKMapView) {
            guard let walkerAnnotation,
                  let walkerView else { return }
            MapHomeAppleWalkerOverlayLayout.update(
                walkerView,
                coordinate: walkerAnnotation.coordinate,
                on: mapView
            )
        }

        private func descriptor(
            for kind: MapHomeAppleAnnotationKind
        ) -> MapHomeAppleHostedDescriptor {
            switch kind {
            case .temporary(_, let title):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text(title)
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
                            destination: place.destination,
                            growthLevel: place.growthLevel,
                            isLeapDay: place.isLeapDay,
                            growthStatus: place.growthStatus,
                            isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                            growthStreak: place.growthStreak,
                            pendingWeeklyRewards: place.pendingWeeklyRewards,
                            showsCatAtHome: place.isCatAtHome,
                            catAction: place.catAction,
                            equippedAccessoryID: place.equippedAccessoryID,
                            weatherBadge: place.weatherBadge
                        )
                        .fixedSize()
                    ),
                    size: CGSize(
                        width: 130,
                        height: place.destination == .home ? MapHomePlacePinLayout.appleHomeHostHeight : 138
                    ),
                    centerOffset: MapHomePlaceAnnotationLayout.appleCenterOffset
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
            case .memo(let memo):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(MapHomeMapMemoMarker(memo: memo)),
                    size: CGSize(width: 150, height: 60),
                    centerOffset: CGPoint(x: 0, y: -30)
                )
            case .pawprint(let paw):
                let color: Color = paw.isSelectedRoute ? .orange
                    : paw.isPredicted ? Color.gray.opacity(0.68)
                    : MapHomePawprintSpeedColor.color(forMetersPerSecond: paw.speedMetersPerSecond)
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(color)
                            .rotationEffect(.degrees(paw.angle))
                    ),
                    size: CGSize(width: 24, height: 24),
                    centerOffset: .zero
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
            if isApplyingSwiftUIUpdate {
                publishCameraFrameAfterUpdate(from: mapView, isFinal: isFinal)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard isFinal || now - lastCameraPublishUptime >= 1.0 / 60.0 else {
                return
            }
            lastCameraPublishUptime = now
            updateWalkerPosition(in: mapView)
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
            let displayedCoordinate = walkerAnnotation?.coordinate
                ?? parent.annotations.first(where: { annotation in
                    guard case .place(let place) = annotation.kind else {
                        return false
                    }
                    return place.destination == .home
                })?.coordinate
                ?? parent.annotations.first(where: { annotation in
                    guard case .place(let place) = annotation.kind else {
                        return false
                    }
                    return place.destination == .user
                })?.coordinate
            let locationPoint = displayedCoordinate.map {
                mapView.convert($0, toPointTo: mapView)
            }
            parent.onCameraFrame(frame, locationPoint, isFinal)
        }

        private func publishCameraFrameAfterUpdate(
            from mapView: MKMapView,
            isFinal: Bool
        ) {
            cameraFramePublishIsFinal = cameraFramePublishIsFinal || isFinal
            guard !cameraFramePublishPending else { return }
            cameraFramePublishPending = true
            Task { @MainActor [weak self, weak mapView] in
                await Task.yield()
                guard let self else { return }
                self.cameraFramePublishPending = false
                let isFinal = self.cameraFramePublishIsFinal
                self.cameraFramePublishIsFinal = false
                guard let mapView else { return }
                self.publishCameraFrame(from: mapView, isFinal: isFinal)
            }
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


// MARK: - RPG marker info

/// 지도 위 마커를 탭했을 때 그 의미를 설명하는 상세 창의 종류.
enum MapHomeMarkerInfoKind: Identifiable, Hashable {
    case cat(MapHomeStickmanAction)
    case pawprint
    case landmark(MapHomeLocationDestination)
    case flag
    case expedition(distanceText: String, placeCount: Int, activityKinds: Int)

    var id: String {
        switch self {
        case .cat(let a): "cat-\(a.rawValue)"
        case .pawprint: "pawprint"
        case .landmark(let d): "landmark-\(d.rawValue)"
        case .flag: "flag"
        case .expedition(let d, let p, let a): "expedition-\(d)-\(p)-\(a)"
        }
    }
}

struct MapHomeMarkerInfoSheet: View {
    let kind: MapHomeMarkerInfoKind
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 52, height: 52)
                    .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Spacer()
            }
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpBackground)
    }

    private var symbol: String {
        switch kind {
        case .cat: "pawprint.circle.fill"
        case .pawprint: "pawprint.fill"
        case .landmark(let d): d.rpgSystemImage
        case .flag: "flag.fill"
        case .expedition: "scroll.fill"
        }
    }

    private var title: String {
        switch kind {
        case .cat(let a): language.text("화랑이 · \(a.title)", "Hwarang · \(a.title)")
        case .pawprint: language.text("발자국 흔적", "Pawprint Trail")
        case .landmark(let d): language.text("랜드마크 · \(d.koreanName)", "Landmark · \(d.englishName)")
        case .flag: language.text("점령 깃발", "Conquered Flag")
        case .expedition: language.text("오늘의 탐험 일지", "Today's Expedition Log")
        }
    }

    private var detail: String {
        switch kind {
        case .cat:
            language.text(
                "탐험가 고양이 화랑이입니다. 지금 내 위치와 활동을 나타내며, 걷기·뛰기·수면·업무 등 활동에 따라 동작이 바뀌고, 이동 속도가 빠를수록 더 다이나믹하게 질주합니다.",
                "Your explorer cat showing your current location and activity. Its motion changes with what you're doing, and the faster you move the more dynamically it dashes."
            )
        case .pawprint:
            language.text(
                "오늘 이동한 경로에 찍힌 고양이 발자국입니다. 발자국을 따라가면 하루 동안 탐험한 길을 되짚어볼 수 있어요.",
                "Cat pawprints stamped along today's route. Follow them to retrace the path you explored."
            )
        case .landmark:
            language.text(
                "자주 방문하는 장소가 판타지 랜드마크로 표시됩니다. 집=오두막, 회사=길드 성, 학교=지식의 탑처럼 각 장소가 고유한 건물로 나타납니다. Lv 배지는 층수입니다.",
                "Frequently visited places appear as fantasy landmarks — home as a lodge, work as a guild castle, school as a tower. The Lv badge is the floor."
            )
        case .flag:
            language.text(
                "방문해서 '점령'한 장소에 꽂히는 깃발입니다. 새로운 곳을 방문할수록 더 많은 깃발이 모입니다.",
                "A flag planted on a place you've visited and 'conquered'. Visit new places to collect more."
            )
        case .expedition(let d, let p, let a):
            language.text(
                "오늘 화랑이의 탐험 기록입니다.\n\n🐾 이동 거리: \(d)\n🚩 방문 장소: \(p)곳\n🎖️ 활동 종류: \(a)종\n\n더 멀리 이동하고 새로운 장소를 방문할수록 탐험 기록이 늘어납니다.",
                "Hwarang's expedition log for today.\n\n🐾 Distance: \(d)\n🚩 Places: \(p)\n🎖️ Activities: \(a)\n\nTravel farther and visit new places to grow your log."
            )
        }
    }
}

/// 하루 요약 시트의 한 줄(대분류 하나). 세부 기록에서 파생한 값만 담는다.
struct MapHomeDaySummaryEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let seconds: TimeInterval
    let ratio: Double
}

/// 지도에서 여는 하루 대분류 요약. 세부 활동은 건드리지 않고, 대분류별
/// 소요 시간과 비중만 막대로 보여준다.
/// 하루 요약 맨 위에 보여 주는 집 성장 카드 값. 집 핀의 성장 값과 같은 출처다.
struct MapHomeGrowthCardInfo: Equatable {
    var level: Int
    var status: String
    var isQualifiedToday: Bool
    var streak: Int
    var pendingWeeklyRewards: Int
}

struct MapHomeDaySummarySheet: View {
    let date: Date
    let categories: [MapHomeDaySummaryEntry]
    let stepCount: Int?
    var travelDistances: [MapHomeDayTravelDistanceEntry] = []
    @Binding var growthData: Data
    let language: MapHomeLanguage
    var growthCard: MapHomeGrowthCardInfo? = nil
    @State private var isGrowthPresented = false
    @State private var contentHeight: CGFloat = 0
    private static let bottomPadding: CGFloat = 40

    private var totalSeconds: TimeInterval {
        categories.reduce(0) { $0 + $1.seconds }
    }

    private func growthCardView(_ card: MapHomeGrowthCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "house.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.tpAccent)
                Text("Lv.\(card.level)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 8)
                Label(language.text("연속 \(card.streak)일", "\(card.streak)-day streak"), systemImage: "flame.fill")
                Label(language.text("보상 \(card.pendingWeeklyRewards)", "Rewards \(card.pendingWeeklyRewards)"), systemImage: "gift.fill")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(card.status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(card.isQualifiedToday ? Color.tpAccent : Color.tpSecondary)
                .lineLimit(2)
            Capsule()
                .fill(card.isQualifiedToday ? Color.tpPastelMint : Color.tpLine.opacity(0.55))
                .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.9), lineWidth: 0.9)
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            summaryContent
                .padding(22)
                .padding(.bottom, Self.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .background(Color.tpBackground)
        // 내용이 늘어도 아래 여백까지 한 화면에 보이도록 시트 높이를 내용에 맞춘다(넘치면 스크롤·큰 시트).
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight + 16), .large] : [.fraction(0.8), .large])
        .sheet(isPresented: $isGrowthPresented) {
            MapHomeGrowthSheet(
                growthData: $growthData,
                language: language
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("하루 요약", "Day Summary"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(dateText)
                    .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                HStack {
                    Spacer()
                    Button {
                        isGrowthPresented = true
                    } label: {
                        Label(
                            language.text("집 성장", "Home growth"),
                            systemImage: "house.and.flag.fill"
                        )
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.tpAccent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(language.text("주간 보상과 집 성장 기록을 엽니다", "Opens weekly rewards and your house history"))
                }
            }

            if let growthCard {
                growthCardView(growthCard)
            }

            if let stepCount {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(Color.tpAccent)
                    Text(language.text("걸음 수", "Steps"))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Text(stepCount.formatted())
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(Color.tpInk)
                }
                .font(.system(size: 14, weight: .medium))
            }

            if categories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    Text(language.text("이 날의 기록이 아직 없습니다", "No records for this day yet"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text(
                    language.text(
                        "총 \(DurationText.korean(totalSeconds)) 기록",
                        "\(DurationText.english(totalSeconds)) recorded"
                    )
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)

                VStack(spacing: 12) {
                    ForEach(categories) { entry in
                        row(entry)
                    }
                }
            }

            if !travelDistances.isEmpty {
                travelDistanceSection
            }
        }
    }

    private var travelDistanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("이동 거리", "Distance by mode"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(travelDistances) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.mode.summarySystemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 24)
                    Text(language.text(entry.mode.summaryKoreanTitle, entry.mode.summaryEnglishTitle))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpInk)
                    Spacer()
                    Text(MapHomeDayTravelSummary.distanceText(entry.meters))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.tpInk)
                }
            }
        }
    }

    private func row(_ entry: MapHomeDaySummaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(entry.tint)
                    .frame(width: 24)
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text("\(Int((entry.ratio * 100).rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(DurationText.localized(entry.seconds, english: language == .english))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(entry.tint.opacity(0.16))
                    Capsule()
                        .fill(entry.tint)
                        .frame(width: max(4, proxy.size.width * entry.ratio))
                }
            }
            .frame(height: 8)
        }
    }

    private var dateText: String {
        MapHomeDateText.string(
            from: date,
            format: language == .english ? "EEE, MMM d" : "M월 d일 EEEE",
            locale: Locale(identifier: language == .english ? "en_US" : "ko_KR")
        )
    }
}

private struct MapHomeGrowthSheet: View {
    @Binding var growthData: Data
    let language: MapHomeLanguage

    @State private var historyCache = MapHomeGrowthHistoryCache()
    @State private var showsTestTools = true
    @State private var showsAllAccessories = false

    private var history: MapHomeGrowthHistory {
        historyCache.history(for: growthData) ?? .initial(for: .now)
    }

    private var season: MapHomeGrowthSeason { history.season }
    private var placements: [MapHomeGrowthPlotPlacement] {
        season.landPlotPlacements ?? []
    }
    private var unplacedPlots: [String] {
        season.landPlots.filter { id in !placements.contains(where: { $0.plotID == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    seasonProgress
                    weeklyRewardSection
                    landSection
                    accessorySection
                    archiveSection
                    if showsTestTools { testToolsSection }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .background(Color.tpBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.and.flag.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.tpAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("우리 집 성장", "Home growth"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(verbatim: "\(season.year) · Lv.\(season.level)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            .contentShape(Rectangle())
            // 제목을 1.5초 길게 누르면 시험 도구가 열린다.
            .onLongPressGesture(minimumDuration: 1.5) { showsTestTools.toggle() }
            Spacer()
            if season.pendingWeeklyRewards > 0 {
                Text(language.text("보상 \(season.pendingWeeklyRewards)", "Rewards \(season.pendingWeeklyRewards)"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.tpAccent.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.tpSurface)
    }

    private var seasonProgress: some View {
        HStack(spacing: 14) {
            Image(MapHomeGrowthPolicy.artworkName(level: season.level))
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .padding(8)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("올해의 집", "This year's home"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(language.text("Lv.\(season.level) / \(MapHomeGrowthPolicy.maximumLevel(year: season.year))", "Lv.\(season.level) / \(MapHomeGrowthPolicy.maximumLevel(year: season.year))"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                ProgressView(value: Double(season.level), total: Double(MapHomeGrowthPolicy.maximumLevel(year: season.year)))
                    .tint(Color.tpPastelMint)
                Text(language.text("연속 달성 \(season.streak)일", "\(season.streak)-day streak"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(14)
        .background(Color.tpSurfaceCream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var weeklyRewardSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("주간 진화 선택", "Weekly evolution"),
                subtitle: language.text("7일 연속 달성 보상 · 하나를 골라요", "7-day streak reward · choose one")
            )
            if season.pendingWeeklyRewards > 0 {
                ForEach(MapHomeLandmarkCatalog.weeklyChoices(for: season)) { candidate in
                    Button {
                        claim(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if UIImage(named: candidate.artworkName) != nil {
                                    Image(candidate.artworkName)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    // 그림이 아직 없는 랜드마크는 무늬 심볼로 대신한다.
                                    Image(systemName: candidate.systemImage)
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(Color(hex: "#D94772"))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.tpAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(candidate))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tpInk)
                                Text("\(countryName(candidate.country)) · \(categoryName(candidate.category))")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .padding(11)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                let remaining = MapHomeGrowthPolicy.daysUntilNextWeeklyReward(streak: season.streak)
                Text(language.text("다음 보상까지 연속 \(remaining)일 남았어요.", "\(remaining) consecutive days until your next reward."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var landSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("연결된 땅", "Connected land"),
                subtitle: language.text("보상을 받아 집 주변에 한 칸씩 이어 붙여요", "Place each earned plot beside your home or another plot")
            )
            if placements.isEmpty && unplacedPlots.isEmpty {
                Text(language.text("첫 주간 보상을 받으면 땅 조각이 생겨요.", "Your first weekly reward will add a land plot."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                landGrid
                Text(language.text(
                    "지도에서 집 근처를 최대로 확대하면 이 땅이 집 주변에 그려지고, 점선 칸을 눌러 바로 이어 붙일 수 있어요.",
                    "Zoom all the way in near your home on the map to see this land and attach plots there."
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                if let next = unplacedPlots.first {
                    Text(language.text(
                        "붙이지 않은 땅 \(unplacedPlots.count)개 · 점선 칸을 눌러 이어 붙여요.",
                        "\(unplacedPlots.count) plots left · tap a dashed cell to attach."
                    ))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    Button {
                        place(next)
                    } label: {
                        Label(language.text("자동으로 붙이기", "Place automatically"), systemImage: "wand.and.stars")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 연결된 땅을 칸 모양 그대로 보여 준다. (0,0)은 집 자리. 붙일 땅이 남아 있으면 이을 수 있는 빈 칸이 점선으로 나온다.
    private var landGrid: some View {
        let candidates = unplacedPlots.isEmpty ? [] : MapHomeGrowthPolicy.placementCandidates(in: season)
        let xs = placements.map(\.x) + candidates.map(\.x)
        let ys = placements.map(\.y) + candidates.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let occupied = Dictionary(uniqueKeysWithValues: placements.map { ("\($0.x),\($0.y)", $0) })
        let candidateKeys = Set(candidates.map { "\($0.x),\($0.y)" })
        let cell: CGFloat = 42
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(minY...maxY, id: \.self) { y in
                    HStack(spacing: 4) {
                        ForEach(minX...maxX, id: \.self) { x in
                            let key = "\(x),\(y)"
                            if occupied[key] != nil {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.tpPastelMint.opacity(0.5))
                                    if x == 0 && y == 0 {
                                        Image(MapHomeGrowthPolicy.artworkName(level: season.level))
                                            .resizable()
                                            .scaledToFit()
                                            .padding(3)
                                    } else {
                                        Image(systemName: "leaf.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.tpAccent)
                                    }
                                }
                                .frame(width: cell, height: cell)
                                .accessibilityLabel(language.text("연결된 땅 조각", "Connected plot"))
                            } else if candidateKeys.contains(key), let plotID = unplacedPlots.first {
                                Button {
                                    placeLand(plotID, x: x, y: y)
                                } label: {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.tpAccent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                                        .overlay {
                                            Image(systemName: "plus")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(Color.tpAccent)
                                        }
                                        .frame(width: cell, height: cell)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("여기에 땅 붙이기", "Attach land here"))
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .padding(2)
        }
    }

    private func placeLand(_ plotID: String, x: Int, y: Int) {
        var updated = history
        guard MapHomeGrowthPolicy.placeLandPlot(plotID, atX: x, y: y, in: &updated.season) else { return }
        save(updated)
    }

    private var accessorySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text(
                    "화랑이 액세서리 \(season.accessories.count) / \(MapHomeLandmarkCatalog.candidates.count)",
                    "Hwarang accessories \(season.accessories.count) / \(MapHomeLandmarkCatalog.candidates.count)"
                ),
                subtitle: language.text("주간 진화 보상으로 모아 착용해요 · 현재 취득 / 전체", "Collect and equip from weekly rewards · owned / total")
            )
            Button {
                showsAllAccessories.toggle()
            } label: {
                Label(
                    language.text(showsAllAccessories ? "전체 도감 접기" : "전체 도감 보기", showsAllAccessories ? "Hide all" : "Show all"),
                    systemImage: showsAllAccessories ? "chevron.up" : "square.grid.3x3.fill"
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpAccent)
            }
            .buttonStyle(.plain)
            if showsAllAccessories { accessoryCollectionGrid }
            if season.accessories.isEmpty {
                Text(language.text("아직 모은 액세서리가 없어요.", "No accessories collected yet."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(season.accessories, id: \.self) { accessoryID in
                    Button {
                        equip(accessoryID)
                    } label: {
                        HStack(spacing: 10) {
                            // 화랑이 아이콘에 달리는 무늬(랜드마크 심볼).
                            Image(systemName: MapHomeGrowthAccessoryCatalog.symbol(for: accessoryID) ?? "sparkles")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color(hex: "#D94772"))
                                .frame(width: 36, height: 36)
                                .background(Color.tpAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accessoryName(accessoryID))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.tpInk)
                                if let landmark = MapHomeGrowthAccessoryCatalog.landmark(for: accessoryID) {
                                    Text("\(countryName(landmark.country)) · \(categoryName(landmark.category))")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                            }
                            Spacer()
                            if season.equippedAccessory == accessoryID {
                                Text(language.text("착용 중", "Equipped"))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tpAccent)
                            }
                            // 지도에서 쓰는 화랑이 아이콘에 이 장식을 단 모습.
                            MapHomeStickmanMarker(action: .sleeping, equippedAccessoryID: accessoryID)
                                .frame(width: 36, height: 36)
                        }
                        .padding(12)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 전체 도감: 모은 장식은 색이 있고 눌러 착용, 못 모은 장식은 회색에 자물쇠.
    private var accessoryCollectionGrid: some View {
        let owned = Set(season.accessories)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(MapHomeLandmarkCatalog.candidates) { candidate in
                let isOwned = owned.contains(candidate.accessoryID)
                Button {
                    if isOwned { equip(candidate.accessoryID) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isOwned ? candidate.systemImage : "lock.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isOwned ? Color(hex: "#D94772") : Color.tpSecondary.opacity(0.5))
                        Text(language == .english ? candidate.englishName : candidate.name)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(isOwned ? Color.tpInk : Color.tpSecondary.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        isOwned ? Color.tpAccent.opacity(0.10) : Color.tpInk.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        if season.equippedAccessory == candidate.accessoryID {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.tpAccent, lineWidth: 1.4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isOwned
                        ? (language == .english ? candidate.englishName : candidate.name)
                        : language.text("아직 모으지 못한 장식", "Not collected yet")
                )
            }
        }
    }

    @ViewBuilder
    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("지난해의 집", "Past homes"),
                subtitle: language.text("매년 새 모닥불에서 시작하고 이전 집은 보관해요", "Each year starts at the campfire; past homes stay saved")
            )
            if history.archives.isEmpty {
                Text(language.text("아직 보관된 집이 없어요.", "No archived homes yet."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(history.archives.reversed(), id: \.year) { archive in
                    HStack(spacing: 10) {
                        Image(MapHomeGrowthPolicy.artworkName(level: archive.level))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(archive.year)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                            Text("Lv.\(archive.level) · \(archive.chosenEvolutions.count) \(language.text("진화", "evolutions"))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text("\(archive.landPlots.count) \(language.text("땅", "plots"))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .padding(10)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private var testToolsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("시험 도구", "Test tools"),
                subtitle: language.text("레벨·보상·저장 형식을 임의로 바꿔 기능을 시험해요", "Change level, rewards, and storage shape to test")
            )
            Text(language.text("집 레벨", "Home level"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testStepper(
                value: "Lv.\(season.level)",
                small: { setTestLevel(season.level - 1) },
                smallUp: { setTestLevel(season.level + 1) },
                large: { setTestLevel(season.level - 10) },
                largeUp: { setTestLevel(season.level + 10) }
            )
            Text(language.text("연속 달성일", "Streak days"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testStepper(
                value: language.text("\(season.streak)일", "\(season.streak) days"),
                small: { adjustTestStreak(-1) },
                smallUp: { adjustTestStreak(1) },
                large: { adjustTestStreak(-7) },
                largeUp: { adjustTestStreak(7) }
            )
            Text(language.text("연속 일수가 7의 배수를 넘으면 주간 보상이 하나씩 생겨요.", "Each multiple of 7 streak days adds a weekly reward."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            Text(language.text("레벨 바로 가기", "Level presets"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach([1, 100, 200, 300, MapHomeGrowthPolicy.maximumLevel(year: season.year), 366], id: \.self) { level in
                    testButton("Lv.\(level)") { setTestLevel(level) }
                }
            }
            Text(language.text("보상·연속", "Rewards and streak"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                testButton(language.text("보상 +1", "Reward +1")) { addTestRewards(streakDays: 0) }
                testButton(language.text("연속 +7일(보상 +1)", "Streak +7 (reward +1)")) { addTestRewards(streakDays: 7) }
            }
            Text(language.text("저장 형식", "Storage shape"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testButton(language.text("이전 형식으로 저장 후 다시 읽기", "Save in the old shape and reload")) { saveLegacyShape() }
            Text(language.text("2026은 365일이라 최대 365입니다. 366은 그림 미리보기용이고, 다음 기록 때 365로 돌아갑니다.", "2026 has 365 days, so the cap is 365. Lv.366 is an artwork preview and returns to the cap on the next record."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    /// 값 한 줄과 −10(−7) / −1 / +1 / +10(+7) 버튼.
    private func testStepper(
        value: String,
        small: @escaping () -> Void,
        smallUp: @escaping () -> Void,
        large: @escaping () -> Void,
        largeUp: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            testButton("−\(value.contains("일") || value.contains("days") ? 7 : 10)", action: large)
            testButton("−1", action: small)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .frame(minWidth: 72)
                .monospacedDigit()
            testButton("+1", action: smallUp)
            testButton("+\(value.contains("일") || value.contains("days") ? 7 : 10)", action: largeUp)
        }
    }

    private func adjustTestStreak(_ delta: Int) {
        var updated = history
        let before = updated.season.streak
        let after = max(0, before + delta)
        updated.season.streak = after
        if after > before {
            updated.season.pendingWeeklyRewards += after / 7 - before / 7
        }
        save(updated)
    }

    private func testButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func setTestLevel(_ level: Int) {
        var updated = history
        updated.season.level = min(max(level, 1), 366)
        save(updated)
    }

    private func addTestRewards(streakDays: Int) {
        var updated = history
        updated.season.streak += streakDays
        updated.season.pendingWeeklyRewards += 1
        save(updated)
    }

    /// 예전 앱이 저장하던 모양(땅 배치·소급 보상 필드 없음)으로 저장해 읽기 호환을 시험한다.
    private func saveLegacyShape() {
        guard let encoded = try? JSONEncoder().encode(history),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return }
        func stripped(_ season: [String: Any]) -> [String: Any] {
            var copy = season
            copy.removeValue(forKey: "landPlotPlacements")
            copy.removeValue(forKey: "recentCompletionRewardedDays")
            return copy
        }
        if let season = object["season"] as? [String: Any] { object["season"] = stripped(season) }
        if let archives = object["archives"] as? [[String: Any]] { object["archives"] = archives.map(stripped) }
        guard let legacy = try? JSONSerialization.data(withJSONObject: object) else { return }
        growthData = legacy
    }

    private func claim(_ candidate: MapHomeLandmarkCandidate) {
        var updated = history
        let plotID = "plot.\(UUID().uuidString)"
        guard MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: candidate.id,
            landPlotID: plotID,
            accessoryID: candidate.accessoryID,
            in: &updated
        ) else { return }
        save(updated)
    }

    private func place(_ plotID: String) {
        var updated = history
        guard MapHomeGrowthPolicy.placeLandPlot(plotID, in: &updated.season) else { return }
        save(updated)
    }

    private func equip(_ accessoryID: String) {
        var updated = history
        guard MapHomeGrowthPolicy.equipAccessory(accessoryID, in: &updated.season) else { return }
        save(updated)
    }

    private func save(_ history: MapHomeGrowthHistory) {
        guard growthData.isEmpty || historyCache.history(for: growthData) != nil,
              let encoded = try? JSONEncoder().encode(history) else { return }
        growthData = encoded
    }

    private func displayName(_ candidate: MapHomeLandmarkCandidate) -> String {
        language == .english ? candidate.englishName : candidate.name
    }

    private func countryName(_ korean: String) -> String {
        guard language == .english else { return korean }
        return [
            "대한민국": "South Korea", "일본": "Japan", "미국": "United States",
            "영국": "United Kingdom", "프랑스": "France", "이탈리아": "Italy",
            "중국": "China", "스페인": "Spain", "태국": "Thailand", "호주": "Australia",
        ][korean] ?? korean
    }

    private func categoryName(_ category: String) -> String {
        guard language == .english else { return category }
        return ["건축": "Architecture", "자연": "Nature", "문화": "Culture"][category] ?? category
    }

    private func accessoryName(_ accessoryID: String) -> String {
        guard let candidate = MapHomeLandmarkCatalog.candidates.first(where: { $0.accessoryID == accessoryID }) else {
            return language.text("화랑이 장식", "Hwarang accessory")
        }
        return language.text("\(candidate.name) 테마 장식", "\(candidate.englishName) charm")
    }
}

struct MapHomeStartupCameraPolicy {
    /// 시작 화면 배율 85(약 550m)로 연다(대표 지시 ZMP1020A01). 이전에는 3,000m였다.
    static let distance: CLLocationDistance = MapHomeCameraZoomMath.distance(forScale: MapHomePlaybackZoomPolicy.baselineScale)
    static let fallbackCenter = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
    private var needsZoomRestore = false

    mutating func shouldRestoreZoom(on phase: ScenePhase) -> Bool {
        if phase == .background { needsZoomRestore = true }
        guard phase == .active else { return false }
        defer { needsZoomRestore = false }
        return needsZoomRestore
    }

    static func camera(restoring camera: MapCamera?, fallbackCenter: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(
            centerCoordinate: camera?.centerCoordinate ?? fallbackCenter,
            distance: distance,
            heading: camera?.heading ?? 0,
            pitch: camera?.pitch ?? 0
        )
    }
}


/// 위치 고르기용 핀: 물방울 모양 몸통과 흰 점, 끝이 닿는 자리에 그림자 타원. 끝이 뷰 아래 가운데에 있다.
struct MapHomePlacementPin: View {
    static let width: CGFloat = 34
    static let height: CGFloat = 46

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Color.black.opacity(0.22))
                .frame(width: 16, height: 6)
                .blur(radius: 1.5)
                .offset(y: 3)
            MapHomePinShape()
                .fill(
                    LinearGradient(
                        colors: [Color.tpReferenceBlue.opacity(0.95), Color(hex: "#1E7ED0")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay { MapHomePinShape().stroke(Color.white, lineWidth: 2) }
                .overlay(alignment: .top) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(y: Self.width * 0.5 - 6)
                }
                .frame(width: Self.width, height: Self.height)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: Self.width, height: Self.height)
    }
}

struct MapHomePinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w / 2, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.38),
                      control1: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.78),
                      control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.62))
        path.addCurve(to: CGPoint(x: rect.minX + w / 2, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.17),
                      control2: CGPoint(x: rect.minX + w * 0.22, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.38),
                      control1: CGPoint(x: rect.minX + w * 0.78, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.17))
        path.addCurve(to: CGPoint(x: rect.minX + w / 2, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.62),
                      control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.78))
        path.closeSubpath()
        return path
    }
}

/// 지도 데이터·타일 제공자의 출처 표기. 지도 위 (i) 버튼과 같은 내용을 메뉴에서도 보여 준다.
struct MapHomeAttributionSheet: View {
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("지도 출처", "Map attribution"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            attributionRow("OpenFreeMap", "© OpenMapTiles · Data from OpenStreetMap")
            attributionRow(
                language.text("지도 데이터", "Map data"),
                "© OpenStreetMap contributors (ODbL)"
            )
            attributionRow(language.text("지도 표시", "Map rendering"), "MapLibre Native")
            Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                Label(language.text("OpenStreetMap 저작권 보기", "OpenStreetMap copyright"), systemImage: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .tint(Color.tpAccent)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tpBackground)
    }

    private func attributionRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.tpInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 설정 > 표시 > 메모: 모두 / 위치 있는 메모만 / 숨김. 시간 메모·시간 없는 메모(왼쪽 위 목록)는 "모두"에서만 보인다.
enum MapHomeMemoDisplayMode: String, CaseIterable, Sendable {
    case all
    case located
    case hidden

    var koreanTitle: String {
        switch self {
        case .all: "모두 표시"
        case .located: "위치 메모만"
        case .hidden: "표시 안 함"
        }
    }

    var englishTitle: String {
        switch self {
        case .all: "Show all"
        case .located: "Located only"
        case .hidden: "Hide"
        }
    }
}

/// 지도 홈 버튼 배치. 하단 탭·떠 있는 독은 재생·녹화·메모·위치·메뉴를 아래 한 곳에 모은다.
enum MapHomeLayoutStyle: String, CaseIterable, Sendable {
    case classic
    case tabBar

    static let storageKey = "mapHomeLayoutStyle"

    var movesActionsToBottom: Bool { self != .classic }

    /// 지도 출처 (i) 버튼이 왼쪽 하단 원형 버튼(높이 44) 바로 위에 오도록 지도 아래에서 띄우는 거리.
    /// 하단 메뉴 높이 + 기준 여백 10 + 버튼 44 + 간격 8.
    static var attributionBottomMargin: CGFloat { MapHomeLayoutStyle.tabBar.bottomReservedHeight + 10 + 44 + 8 }

    /// 하단 막대가 차지하는 높이. 레일과 왼쪽 버튼을 이만큼 위로 올린다.
    var bottomReservedHeight: CGFloat {
        switch self {
        case .classic: 0
        case .tabBar: 70
        }
    }

    var koreanTitle: String {
        switch self {
        case .classic: "지금"
        case .tabBar: "하단 탭"
        }
    }

    var englishTitle: String {
        switch self {
        case .classic: "Classic"
        case .tabBar: "Bottom tabs"
        }
    }
}

/// 재생 중 지도 배율 방식. 고정이면 재생을 시작할 때의 배율을 그대로 둔다.
enum MapHomePlaybackZoomMode: String, CaseIterable, Sendable {
    case adaptive
    case fixed

    static let storageKey = "mapHomePlaybackZoomMode"

    var koreanTitle: String { self == .fixed ? "현재 배율로 고정" : "속도에 따라 가변" }
    var englishTitle: String { self == .fixed ? "Keep current zoom" : "Vary with speed" }
}


struct MapHomeDayTravelDistanceEntry: Identifiable, Equatable {
    let mode: TravelMode
    let meters: Double
    var id: TravelMode { mode }
}

/// 하루 요약의 이동 수단별 거리. 확인된 수단만 거리가 긴 순서로 보여준다.
enum MapHomeDayTravelSummary {
    static let minimumMeters = 10.0

    static func entries(from segments: [TravelSegment]) -> [MapHomeDayTravelDistanceEntry] {
        var totals: [TravelMode: Double] = [:]
        for segment in segments where segment.distanceMeters.isFinite && segment.distanceMeters > 0 {
            totals[segment.mode, default: 0] += segment.distanceMeters
        }
        return totals
            .filter { $0.value >= minimumMeters }
            .map { MapHomeDayTravelDistanceEntry(mode: $0.key, meters: $0.value) }
            .sorted { $0.meters != $1.meters ? $0.meters > $1.meters : $0.mode.rawValue < $1.mode.rawValue }
    }

    static func distanceText(_ meters: Double) -> String {
        meters < 1_000
            ? "\(Int(meters.rounded())) m"
            : String(format: "%.1f km", meters / 1_000)
    }
}

private extension TravelMode {
    var summarySystemImage: String {
        switch self {
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

    var summaryKoreanTitle: String {
        switch self {
        case .walking: "걷기"
        case .running: "뛰기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "운전"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    var summaryEnglishTitle: String {
        switch self {
        case .walking: "Walking"
        case .running: "Running"
        case .cycling: "Cycling"
        case .bus: "Bus"
        case .subway: "Subway"
        case .taxi: "Taxi"
        case .car: "Driving"
        case .train: "Train"
        case .airplane: "Flight"
        case .ship: "Ferry"
        }
    }
}
