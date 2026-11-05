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
