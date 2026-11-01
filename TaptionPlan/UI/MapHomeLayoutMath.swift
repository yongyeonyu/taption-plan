import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeRouteCoordinateBounds {
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
