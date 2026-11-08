import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

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

    /// 현재 위치 둘레만 먼저 찾고, 그 안에 하나도 없을 때만 넓혀 찾는다(SRC1108A01). 일본에 가면 일본이 먼저다.
    func update(query: String, region: MKCoordinateRegion) {
        completer.region = region
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            clear()
        } else if completer.queryFragment != value {
            completer.regionPriority = .required
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
        if completer.results.isEmpty, completer.regionPriority == .required, !completer.queryFragment.isEmpty {
            completer.regionPriority = .default
            completer.cancel()
            let fragment = completer.queryFragment
            completer.queryFragment = ""
            completer.queryFragment = fragment
            return
        }
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
