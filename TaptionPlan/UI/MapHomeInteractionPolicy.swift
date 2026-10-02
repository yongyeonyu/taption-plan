import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum RouteMapLineStyle {
    static let lineWidth: CGFloat = 3
    static let minimumOpacity: Double = 0.72
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
    static let loading: Double = 3
    static let search: Double = 4
    static let menu: Double = 6
    static let header: Double = 8
}

enum MapHomeAppleAnnotationLayerPriority {
    static let userLocation: CGFloat = 0
    static let place: CGFloat = 0
    static let stickman: CGFloat = 100
}

enum MapHomeAppleWalkerOverlayLayout {
    @MainActor
    static func update(_ view: UIView, coordinate: CLLocationCoordinate2D, on mapView: MKMapView) {
        guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        if view.superview !== mapView {
            mapView.addSubview(view)
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.stickman
            mapView.bringSubviewToFront(view)
        }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let offset = MapHomeStickmanAnnotationLayout.centerOffset
        UIView.performWithoutAnimation {
            view.center = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        }
    }
}

enum MapHomeCameraLayoutMath {
    static let centeredTolerance: CGFloat = 18

    static func targetPoint(
        viewportSize: CGSize,
        searchBottom: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2,
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

    @MainActor
    static func isAnnotationTouch(_ view: UIView?) -> Bool {
        var currentView = view
        while let current = currentView {
            if current is MKAnnotationView { return true }
            currentView = current.superview
        }
        return false
    }

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

enum MapHomeCatTapRouting {
    static let hitRadius: CGFloat = 36
    static let homeIconHitRadius: CGFloat = 18
    static let homeImageCenterOffset = CGPoint(x: 0, y: 30)
    static let catOffsetInHomeImage = CGPoint(x: 23, y: 10)
    static let homeMarkerOffset = CGPoint(
        x: homeImageCenterOffset.x + catOffsetInHomeImage.x,
        y: homeImageCenterOffset.y + catOffsetInHomeImage.y
    )
    static let roamingMarkerOffset = MapHomeStickmanAnnotationLayout.centerOffset

    static func markerPoint(locationPoint: CGPoint, isAtHome: Bool) -> CGPoint {
        let offset = isAtHome ? homeMarkerOffset : roamingMarkerOffset
        return CGPoint(
            x: locationPoint.x + offset.x,
            y: locationPoint.y + offset.y
        )
    }

    static func contains(
        tapPoint: CGPoint,
        markerPoint: CGPoint,
        radius: CGFloat = hitRadius
    ) -> Bool {
        hypot(tapPoint.x - markerPoint.x, tapPoint.y - markerPoint.y)
            <= radius
    }

    static func isHomeIconTap(tapPoint: CGPoint, locationPoint: CGPoint) -> Bool {
        let homeIconPoint = CGPoint(
            x: locationPoint.x + homeImageCenterOffset.x,
            y: locationPoint.y + homeImageCenterOffset.y
        )
        return contains(
            tapPoint: tapPoint,
            markerPoint: homeIconPoint,
            radius: homeIconHitRadius
        )
    }

    static func shouldPresentCatDetails(
        tapPoint: CGPoint,
        locationPoint: CGPoint,
        isAtHome: Bool
    ) -> Bool {
        guard !isAtHome || !isHomeIconTap(
            tapPoint: tapPoint,
            locationPoint: locationPoint
        ) else { return false }
        return contains(
            tapPoint: tapPoint,
            markerPoint: markerPoint(locationPoint: locationPoint, isAtHome: isAtHome)
        )
    }
}

enum MapHomeLongPressAction: String, CaseIterable, Identifiable {
    case location
    case memo

    var id: Self { self }
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
    private var lastParentReadbackUptime = -Double.infinity

    func submit(
        _ frame: MapHomeCameraFrame,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> MapHomeCameraFrame? {
        latestFrame = frame
        guard renderedFrame != frame else { return nil }
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
        renderedFrame = frame
        return frame
    }

    func finish(nowUptime: TimeInterval) -> MapHomeCameraFrame? {
        guard let latestFrame else { return nil }
        return submit(latestFrame, nowUptime: nowUptime, force: true)
    }

    func shouldPublishParentReadback(
        nowUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        guard isFinal || nowUptime - lastParentReadbackUptime >= 1.0 / 30.0
        else { return false }
        lastParentReadbackUptime = nowUptime
        return true
    }

    func reset() {
        latestFrame = nil
        renderedFrame = nil
        lastParentReadbackUptime = -Double.infinity
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
        if let renderedPoint,
           abs(renderedPoint.x - point.x) <= 0.25,
           abs(renderedPoint.y - point.y) <= 0.25 {
            return nil
        }
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
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
        isFinal
    }
}
