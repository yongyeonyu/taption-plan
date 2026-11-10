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
    /// 지하철 근거로 경로를 대신 그릴 만큼 믿을 수 있는가 (REV1110A04: 경로 좌표와 같은 기준).
    public static func isTrusted(_ subway: SubwayRouteEvidence) -> Bool {
        subway.stationNames.count >= 2 && subway.coordinates.count >= 2 && subway.confidence >= 0.5
    }

    public static func allowsDottedRoute(_ evidence: MissingRouteEvidence) -> Bool {
        if let subway = evidence.subway, isTrusted(subway) {
            return true
        }
        let signals = [evidence.motionDetected, evidence.cellularContinuity, evidence.subwayWiFi].filter { $0 }.count
        return signals >= 2 && evidence.observedDistanceMeters > 0
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
