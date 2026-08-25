import Foundation

public struct MissingRouteEvidence: Hashable, Sendable {
    public var motionDetected: Bool
    public var cellularContinuity: Bool
    public var subwayWiFi: Bool
    public var subway: SubwayRouteEvidence?
    public var observedDistanceMeters: Double

    public init(
        motionDetected: Bool = false,
        cellularContinuity: Bool = false,
        subwayWiFi: Bool = false,
        subway: SubwayRouteEvidence? = nil,
        observedDistanceMeters: Double = 0
    ) {
        self.motionDetected = motionDetected
        self.cellularContinuity = cellularContinuity
        self.subwayWiFi = subwayWiFi
        self.subway = subway
        self.observedDistanceMeters = observedDistanceMeters
    }
}

public enum RouteEvidenceGate {
    public static func allowsDottedRoute(_ evidence: MissingRouteEvidence) -> Bool {
        if let subway = evidence.subway, subway.stationNames.count >= 2, subway.coordinates.count >= 2, subway.confidence >= 0.5 {
            return true
        }
        let signals = [evidence.motionDetected, evidence.cellularContinuity, evidence.subwayWiFi].filter { $0 }.count
        return signals >= 2 && evidence.observedDistanceMeters > 0
    }

    public static func preferredMode(_ evidence: MissingRouteEvidence) -> RouteTravelMode {
        if allowsDottedRoute(evidence), evidence.subway != nil { return .subway }
        return .unknown
    }
}

public enum SubwayRoutePrecedence {
    public static func resolve(
        gps: [RouteSample],
        evidence: SubwayRouteEvidence?
    ) -> [RouteCoordinate] {
        guard let evidence,
              evidence.stationNames.count >= 2,
              evidence.coordinates.count >= 2,
              evidence.confidence >= 0.5 else {
            return gps.map(\.coordinate)
        }
        return evidence.coordinates
    }
}

public enum RoutePlaybackPolicy {
    public static func rate(currentSpeedMetersPerSecond: Double, movementDetected: Bool) -> Double {
        let speed = max(0, currentSpeedMetersPerSecond)
        return movementDetected ? speed / 4 : speed
    }

    public static func duration(distanceMeters: Double, currentSpeedMetersPerSecond: Double, movementDetected: Bool) -> TimeInterval? {
        let rate = rate(currentSpeedMetersPerSecond: currentSpeedMetersPerSecond, movementDetected: movementDetected)
        guard rate > 0, distanceMeters >= 0 else { return nil }
        return distanceMeters / rate
    }
}
