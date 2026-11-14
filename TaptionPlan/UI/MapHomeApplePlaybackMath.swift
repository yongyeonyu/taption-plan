import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

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

enum MapHomeAppleRoutePhase {
    case actual
    case forecast
}

enum MapHomeAppleRouteTransport: String {
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

struct MapHomeAppleRoute {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let geometrySignature: Int
    let colorHex: String
    let opacity: Double
    let phase: MapHomeAppleRoutePhase
    let transport: MapHomeAppleRouteTransport?
}

enum MapHomeAppleAnnotationKind {
    case temporary(stationName: String, title: String)
    case place(MapHomePlaceAnnotation)
    case transit(MapHomeTransitAnnotation)
    case boarding(TransitBoardingCandidate)
    case sticker(MapSticker)
    case memo(ActionMemo)
    case photo(MapHomePhotoCluster, coverID: String, isHighlighted: Bool)
    case search(MapHomeSearchResult)
    case pawprint(MapHomeApplePawprint)
    case travelStop(number: Int, status: TripItemStatus = .planned)
}

extension MapHomeAppleAnnotationKind {
    /// 스티커 모드의 스티커와 검색 핀만 터치를 직접 받는다(벡터 지도와 같다).
    var passesTouchesToMap: Bool {
        switch self {
        case .sticker, .search: false
        default: true
        }
    }

    var staysVisible: Bool {
        switch self {
        case .sticker, .memo, .photo: true
        default: false
        }
    }

    /// 내용 비교용 해시. `String(describing:)`는 반사(reflection)라 발자국 수백 개에 쓰면 본문 평가마다 수 ms가 들었다(CTR1103A02).
    func combineContent(into hasher: inout Hasher) {
        switch self {
        case .temporary(let stationName, let title):
            hasher.combine(0); hasher.combine(stationName); hasher.combine(title)
        case .place(let place):
            hasher.combine(1); place.combineContent(into: &hasher)
        case .transit(let place):
            hasher.combine(2); hasher.combine(place.id); hasher.combine(place.name); hasher.combine(place.kind)
        case .boarding(let candidate):
            hasher.combine(3); hasher.combine(candidate)
        case .sticker(let sticker):
            hasher.combine(4); hasher.combine(sticker)
        case .memo(let memo):
            hasher.combine(5); hasher.combine(memo)
        case .photo(let cluster, let coverID, let isHighlighted):
            hasher.combine(8); hasher.combine(cluster.id); hasher.combine(cluster.count); hasher.combine(coverID); hasher.combine(isHighlighted)
        case .search(let result):
            hasher.combine(6); hasher.combine(result.title); hasher.combine(result.subtitle)
        case .travelStop(let number, let status):
            hasher.combine(9); hasher.combine(number); hasher.combine(status)
        case .pawprint(let paw):
            hasher.combine(7); hasher.combine(paw.index); hasher.combine(paw.angle)
            hasher.combine(paw.isPredicted); hasher.combine(paw.isSelectedRoute); hasher.combine(paw.speedMetersPerSecond)
        }
    }
}

extension MapHomePlaceAnnotation {
    fileprivate func combineContent(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(floor); hasher.combine(destination)
        hasher.combine(growthLevel); hasher.combine(isLeapDay); hasher.combine(growthStatus)
        hasher.combine(isGrowthQualifiedToday); hasher.combine(growthStreak); hasher.combine(pendingWeeklyRewards)
        hasher.combine(isCatAtHome); hasher.combine(catAction); hasher.combine(equippedAccessoryID)
        hasher.combine(weatherBadge?.symbolName); hasher.combine(weatherBadge?.temperatureText)
        hasher.combine(weatherBadge?.condition); hasher.combine(weatherBadge?.windSpeedMetersPerSecond)
        hasher.combine(homeSky?.selectedDay); hasher.combine(homeSky?.isPlaybackRunning)
    }
}

/// Apple 지도에 그릴 발자국 하나. 벡터 지도의 `PawprintWaypoint`와 같은 정보를 값으로 옮긴 것이다.
struct MapHomeApplePawprint: Equatable {
    let index: Int
    let angle: Double
    let isPredicted: Bool
    let isSelectedRoute: Bool
    let speedMetersPerSecond: Double?
}

struct MapHomeAppleAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: MapHomeAppleAnnotationKind
    let accessibilityLabel: String
    let isInteractive: Bool
}

struct MapHomeApplePlayback {
    let coordinate: CLLocationCoordinate2D
    let cameraCoordinate: CLLocationCoordinate2D
    let headingDegrees: CLLocationDirection
    let action: MapHomeStickmanAction
    let accessibilityLabel: String
    let phase: MapHomeAppleRoutePhase
    let followsUserLocation: Bool
    let equippedAccessoryID: String?
    let stickmanAnimationPhase: Int?
    var rideLabel: String? = nil
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
        // 복사본은 언제나 MKMapCamera지만, 캐스팅이 실패해 앱이 죽는 것보다는
        // 거리만 못 바꾸고 중심 이동은 그대로 하는 편이 낫다.
        if let distance, distance.isFinite, distance > 0,
           let camera = mapView.camera.copy() as? MKMapCamera {
            // 거리와 중심을 한 번에 놓는다. 나눠 놓으면 그 사이 "거리만 바뀐" 화면이 콜백과 렌더러로 새어
            // 화랑이 위 카운터가 표적점과 화면 중심의 차이만큼 위아래로 튀었다(CTR1103A02).
            if camera.pitch < 1, let targetPoint, mapView.bounds.width > 0, camera.centerCoordinateDistance > 0 {
                camera.centerCoordinate = mapView.convert(
                    MapHomeCameraLayoutMath.cameraCenterSourcePoint(
                        currentLocationPoint: mapView.convert(coordinate, toPointTo: mapView),
                        targetPoint: targetPoint,
                        viewportSize: mapView.bounds.size,
                        zoomScale: CGFloat(camera.centerCoordinateDistance / distance)
                    ),
                    toCoordinateFrom: mapView
                )
                camera.centerCoordinateDistance = distance
                mapView.setCamera(camera, animated: false)
                return
            }
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
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
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
                      point.horizontalAccuracy <= 100,
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
        // 붙은 두 표본은 몇 m 잡음에도 방향이 뒤집힌다. 앞뒤 창 안에서 충분히 움직인 두 점을 쓰고,
        // 움직임이 없으면 nil이다. 예전에는 이때 하루 마지막 두 표본의 방향을 썼다(DIR1106A01).
        var low = 0, high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].0 <= date { low = middle + 1 } else { high = middle }
        }
        let window = headingWindow
        // 매 프레임 불리므로 창 밖까지 훑지 않는다.
        var first = low
        while first > 0, date.timeIntervalSince(points[first - 1].0) <= window { first -= 1 }
        var last = low
        while last < points.count, points[last].0.timeIntervalSince(date) <= window { last += 1 }
        guard last - first >= 2, let from = points[first..<last].first, let to = points[first..<last].last,
              distanceMeters(from.1, to.1) >= minimumHeadingMeters else { return nil }
        return stableHeading(bearing(from: from.1, to: to.1))
    }

    /// 방향을 구할 앞뒤 시간 창과 그 안에서 움직였다고 볼 거리.
    static let headingWindow: TimeInterval = 15
    static let minimumHeadingMeters = 12.0

    private static func distanceMeters(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
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

/// 화랑이가 탄 버스 번호·지하철 노선 글(RDL1114A01). 모르면 「?」이고, 누르면 후보를 고른다(RDQ1114A01).
@MainActor
enum MapHomeRideLabel {
    nonisolated static let unknown = "?"
    private static var cached: (id: UUID, text: String, at: Date)?

    static func segment(at date: Date, travel: [TravelSegment]) -> TravelSegment? {
        travel.filter { ($0.mode == .bus || $0.mode == .subway) && $0.span.contains(date) }.max(by: { $0.span.start < $1.span.start })
    }

    static func text(at date: Date, travel: [TravelSegment], now: Date = .now) -> String? {
        guard let segment = segment(at: date, travel: travel) else { return nil }
        // 고르거나 AI가 정하면 곧 바뀌어야 하니 잠깐만 적어 둔다.
        if let cached, cached.id == segment.id, now.timeIntervalSince(cached.at) < 3 { return cached.text }
        var text = text(for: segment)
        // 노선 조회가 없던 날의 버스도, 그 시각의 교통 지출에 번호가 적혀 있으면(「버스 요금 · 80번」) 그 번호를 쓰고 기억해 둔다(RDF1114A01).
        if text == unknown, segment.mode == .bus, let number = busNumber(in: LedgerBook.shared.entries, for: segment) {
            BusRouteCheck.remember(segment, routes: [.init(number: number, kind: "")])
            text = number
        }
        cached = (segment.id, text, now)
        return text
    }

    /// 탄 시각 앞뒤 30분 안의 교통 지출 제목에서 「80번」 같은 번호를 찾는다. 서로 다른 번호가 둘 이상이면 정하지 않는다.
    nonisolated static func busNumber(in entries: [LedgerEntry], for segment: TravelSegment) -> String? {
        let window = segment.span.start.addingTimeInterval(-1_800)...segment.span.end.addingTimeInterval(1_800)
        var numbers: [String] = []
        for entry in entries where entry.category == .transport && window.contains(entry.occurredAt) {
            guard let match = entry.title.range(of: #"[0-9A-Za-z가-힣-]{1,8}번"#, options: .regularExpression) else { continue }
            let number = String(entry.title[match].dropLast())
            if !numbers.contains(number) { numbers.append(number) }
        }
        return numbers.count == 1 ? numbers[0] : nil
    }

    /// 버스는 「80」(둘이면 「80·81」), 지하철은 「1호선」(갈아탔으면 「1호선→2호선」), 못 정했으면 「?」.
    nonisolated static func text(for segment: TravelSegment, defaults: UserDefaults = .standard) -> String {
        // 서버 규칙(AIX1114A01 P3): 이 승하차 쌍의 번호·노선을 배워 둔 것이 있으면 그것.
        if let names = BusRouteCheck.stopNames(segment, defaults: defaults), segment.mode == .bus || segment.mode == .subway,
           let learned = RuleEngine.rideLine(board: names.board, alight: names.alight, mode: segment.mode == .bus ? "bus" : "subway", rules: AssistantRuleSnapshot.rules) {
            return learned.line
        }
        switch segment.mode {
        case .bus:
            if let routes = BusRouteCheck.known(segment, defaults: defaults), (1...2).contains(routes.count) { return routes.map(\.number).joined(separator: "·") }
            // 판정할 때 근거에 적어 둔 노선(「노선 80」, 「노선 80·81」).
            let noted = segment.evidence.first { $0.hasPrefix("노선 ") }.map { $0.dropFirst(3).split(separator: "·").map(String.init) } ?? []
            return (1...2).contains(noted.count) ? noted.joined(separator: "·") : unknown
        case .subway:
            let lines = segment.subwayRoute?.lineNames ?? []
            if !lines.isEmpty { return lines.prefix(3).joined(separator: "→") }
            return SubwayLineChoice.known(segment, defaults: defaults) ?? unknown
        default:
            return unknown
        }
    }
}

/// 탈것 그림 바로 위에 놓이는 번호·노선 이름표.
struct MapHomeRideLabelBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .heavy))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.tpSurface.opacity(0.98), in: Capsule())
            .overlay { Capsule().stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
            .alignmentGuide(.top) { $0[.bottom] + 2 }
    }
}
