import Foundation

public struct RouteGapInferenceInput: Sendable {
    public let start: Date
    public let end: Date
    public let startCoordinate: RouteCoordinate
    public let endCoordinate: RouteCoordinate
    public let samples: [RouteSample]
    public let precedingMode: RouteTravelMode
    public let followingMode: RouteTravelMode
    public let explicitMode: RouteTravelMode
    public let endpointConfidence: Double

    public init(
        start: Date,
        end: Date,
        startCoordinate: RouteCoordinate,
        endCoordinate: RouteCoordinate,
        samples: [RouteSample] = [],
        precedingMode: RouteTravelMode = .unknown,
        followingMode: RouteTravelMode = .unknown,
        explicitMode: RouteTravelMode = .unknown,
        endpointConfidence: Double = 1
    ) {
        self.start = start
        self.end = end
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.samples = samples
        self.precedingMode = precedingMode
        self.followingMode = followingMode
        self.explicitMode = explicitMode
        self.endpointConfidence = min(1, max(0, endpointConfidence))
    }
}

public struct RouteGapInferenceDecision: Hashable, Sendable {
    public let mode: RouteTravelMode?
    public let confidence: Double
    public let provenance: String

    public init(mode: RouteTravelMode?, confidence: Double, provenance: String) {
        self.mode = mode
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }

    public var allowsConnection: Bool { mode != nil }
}

public struct RouteGapInferenceConfiguration: Hashable, Sendable {
    public var maximumGapDuration: TimeInterval
    public var minimumDistanceMeters: Double
    public var maximumDistanceMeters: Double
    public var minimumEndpointConfidence: Double
    public var minimumAverageSpeedMetersPerSecond: Double

    public init(
        maximumGapDuration: TimeInterval = 4 * 60 * 60,
        minimumDistanceMeters: Double = 20,
        maximumDistanceMeters: Double = 500_000,
        minimumEndpointConfidence: Double = 0.6,
        minimumAverageSpeedMetersPerSecond: Double = 0.1
    ) {
        self.maximumGapDuration = maximumGapDuration
        self.minimumDistanceMeters = minimumDistanceMeters
        self.maximumDistanceMeters = maximumDistanceMeters
        self.minimumEndpointConfidence = minimumEndpointConfidence
        self.minimumAverageSpeedMetersPerSecond = max(
            0,
            minimumAverageSpeedMetersPerSecond
        )
    }
}

public struct RouteGapInferenceEngine: Sendable {
    public let configuration: RouteGapInferenceConfiguration

    public init(configuration: RouteGapInferenceConfiguration = .init()) {
        self.configuration = configuration
    }

    public func infer(_ input: RouteGapInferenceInput) -> RouteGapInferenceDecision {
        let duration = input.end.timeIntervalSince(input.start)
        let distance = routeDistance(input.startCoordinate, input.endCoordinate)
        guard duration > 0,
              duration <= configuration.maximumGapDuration,
              distance >= configuration.minimumDistanceMeters,
              distance <= configuration.maximumDistanceMeters,
              input.endpointConfidence >= configuration.minimumEndpointConfidence else {
            return .init(mode: nil, confidence: 0, provenance: "gap-constraints-rejected")
        }
        if input.explicitMode != .unknown,
           plausible(mode: input.explicitMode, distance: distance, duration: duration) {
            return .init(mode: input.explicitMode, confidence: 1, provenance: "explicit-travel-mode")
        }

        let evidenceModes = input.samples
            .filter { $0.timestamp >= input.start && $0.timestamp <= input.end }
            .map(\.mode)
            .filter { $0 != .unknown }
        if let mode = strongest(evidenceModes),
           plausible(mode: mode, distance: distance, duration: duration) {
            let count = evidenceModes.filter { $0 == mode }.count
            return .init(
                mode: mode,
                confidence: min(0.95, 0.65 + Double(count) * 0.05),
                provenance: "filtered-sensor-mode"
            )
        }
        if input.precedingMode != .unknown,
           input.precedingMode == input.followingMode,
           plausible(mode: input.precedingMode, distance: distance, duration: duration) {
            return .init(
                mode: input.precedingMode,
                confidence: 0.65,
                provenance: "matching-adjacent-modes"
            )
        }
        return .init(mode: nil, confidence: 0, provenance: "insufficient-route-evidence")
    }

    private func strongest(_ modes: [RouteTravelMode]) -> RouteTravelMode? {
        let counts = Dictionary(grouping: modes, by: { $0 }).mapValues(\.count)
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return priority(lhs.key) < priority(rhs.key)
        }?.key
    }

    private func priority(_ mode: RouteTravelMode) -> Int {
        switch mode {
        case .subway: 5
        case .airplane: 6
        case .ship: 4
        case .train: 5
        case .automotive: 4
        case .privateVehicle: 4
        case .cycling: 3
        case .bus: 3
        case .running: 2
        case .walking: 1
        case .unknown: 0
        }
    }

    private func plausible(
        mode: RouteTravelMode,
        distance: Double,
        duration: TimeInterval
    ) -> Bool {
        let speed = distance / duration
        let minimumSpeed: Double = switch mode {
        case .subway, .bus, .train, .ship: 0
        default: configuration.minimumAverageSpeedMetersPerSecond
        }
        return speed >= minimumSpeed
            && speed <= mode.maximumSpeedMetersPerSecond * 1.25
    }

    private func routeDistance(
        _ lhs: RouteCoordinate,
        _ rhs: RouteCoordinate
    ) -> Double {
        let latitude = (lhs.latitude + rhs.latitude) * .pi / 360
        let north = (rhs.latitude - lhs.latitude) * 111_320
        let east = (rhs.longitude - lhs.longitude) * 111_320 * cos(latitude)
        return hypot(north, east)
    }
}
