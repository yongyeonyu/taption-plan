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

    /// 늘 지역을 묶어 찾는다(`.required`). 현재 위치 둘레(약 55km)에 없으면 반경을 6배씩 두 번까지만 넓힌다.
    /// 전 세계로 넘기면 한글 조합 중 잠깐 빈 결과에도 미국·홍콩 결과가 떴다(SRC1108A02). 일본에 가면 일본 둘레에서 찾는다.
    private var baseRegion = MKCoordinateRegion()
    private var widenStep = 0
    static let widenFactor = 6.0
    static let maxWidenSteps = 2

    func update(query: String, region: MKCoordinateRegion) {
        baseRegion = region
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            clear()
        } else if completer.queryFragment != value {
            widenStep = 0
            completer.regionPriority = .required
            completer.region = region
            completer.queryFragment = value
        }
    }

    func clear() {
        widenStep = 0
        if !completer.queryFragment.isEmpty {
            completer.queryFragment = ""
        }
        if !results.isEmpty {
            results = []
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let fragment = completer.queryFragment
        if completer.results.isEmpty, !fragment.isEmpty, widenStep < Self.maxWidenSteps {
            widenStep += 1
            completer.region = Self.widened(baseRegion, step: widenStep)
            completer.cancel()
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

    static func widened(_ region: MKCoordinateRegion, step: Int) -> MKCoordinateRegion {
        let factor = pow(widenFactor, Double(step))
        return MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: min(region.span.latitudeDelta * factor, 60),
                longitudeDelta: min(region.span.longitudeDelta * factor, 60)
            )
        )
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
