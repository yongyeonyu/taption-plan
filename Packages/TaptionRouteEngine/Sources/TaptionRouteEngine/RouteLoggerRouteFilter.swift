import Foundation

public struct RouteLoggerRouteFilterConfiguration: Sendable {
    public var stationaryRadiusMeters: Double
    public var stationarySpeedMetersPerSecond: Double
    public var segmentGap: TimeInterval
    public var maximumAccuracyForPathMeters: Double
    public var maximumAccuracyForBoundaryMeters: Double
    public var maximumUnknownSpeedMetersPerSecond: Double
    public var absoluteMaximumSpeedMetersPerSecond: Double
    public var innovationGate: Double
    public var processAccelerationNoise: Double

    public init(
        stationaryRadiusMeters: Double = 3,
        stationarySpeedMetersPerSecond: Double = 0.75,
        segmentGap: TimeInterval = 15 * 60,
        maximumAccuracyForPathMeters: Double = 150,
        maximumAccuracyForBoundaryMeters: Double = 1_000,
        maximumUnknownSpeedMetersPerSecond: Double = 55,
        absoluteMaximumSpeedMetersPerSecond: Double = 120,
        innovationGate: Double = 9,
        processAccelerationNoise: Double = 4
    ) {
        self.stationaryRadiusMeters = stationaryRadiusMeters
        self.stationarySpeedMetersPerSecond = stationarySpeedMetersPerSecond
        self.segmentGap = segmentGap
        self.maximumAccuracyForPathMeters = maximumAccuracyForPathMeters
        self.maximumAccuracyForBoundaryMeters = maximumAccuracyForBoundaryMeters
        self.maximumUnknownSpeedMetersPerSecond = maximumUnknownSpeedMetersPerSecond
        self.absoluteMaximumSpeedMetersPerSecond = absoluteMaximumSpeedMetersPerSecond
        self.innovationGate = innovationGate
        self.processAccelerationNoise = processAccelerationNoise
    }
}

public enum RouteSampleDecisionReason: String, Codable, Hashable, Sendable {
    case acceptedPath
    case lowConfidenceBoundary
    case lowConfidenceSuppressed
    case duplicate
    case invalidCoordinate
    case invalidAccuracy
    case stationarySuppressed
    case impossibleSpeed
    case innovationOutlier
}

public struct RouteSampleDecision: Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let reason: RouteSampleDecisionReason

    public init(id: UUID, timestamp: Date, reason: RouteSampleDecisionReason) {
        self.id = id
        self.timestamp = timestamp
        self.reason = reason
    }
}

public struct RouteFilterResult: Codable, Hashable, Sendable {
    public let log: RouteLog
    public let decisions: [RouteSampleDecision]

    public init(log: RouteLog, decisions: [RouteSampleDecision]) {
        self.log = log
        self.decisions = decisions
    }
}

/// Creates a deterministic display projection while leaving every raw sample intact.
public struct RouteLoggerRouteFilter: Sendable {
    public let configuration: RouteLoggerRouteFilterConfiguration

    public init(configuration: RouteLoggerRouteFilterConfiguration = .init()) {
        self.configuration = configuration
    }

    public func filter(_ input: [RouteSample]) -> RouteLog {
        filterWithReport(input).log
    }

    public func filterWithReport(_ input: [RouteSample]) -> RouteFilterResult {
        var decisions: [RouteSampleDecision] = []
        let coordinateValid = input.filter { sample in
            guard sample.isUsable else {
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .invalidCoordinate))
                return false
            }
            guard sample.horizontalAccuracyMeters.isFinite,
                  sample.horizontalAccuracyMeters >= 0,
                  sample.horizontalAccuracyMeters <= configuration.maximumAccuracyForBoundaryMeters else {
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .invalidAccuracy))
                return false
            }
            return true
        }
        let normalized = Self.normalizeDuplicates(coordinateValid)
        let selectedIDs = Set(normalized.map(\.id))
        decisions += coordinateValid.compactMap { sample in
            selectedIDs.contains(sample.id) ? nil : RouteSampleDecision(
                id: sample.id,
                timestamp: sample.timestamp,
                reason: .duplicate
            )
        }
        guard !normalized.isEmpty else {
            return .init(
                log: RouteLog(segments: [], normalizedSamples: []),
                decisions: decisions.sorted(by: Self.decisionOrder)
            )
        }

        let boundaries = boundarySamples(from: normalized)
        let boundaryIDs = Set(boundaries.map(\.id))
        decisions += normalized.filter { !$0.isPrecisePathSample(configuration) }.map {
            .init(
                id: $0.id,
                timestamp: $0.timestamp,
                reason: boundaryIDs.contains($0.id)
                    ? .lowConfidenceBoundary
                    : .lowConfidenceSuppressed
            )
        }

        let precise = normalized.filter { $0.isPrecisePathSample(configuration) }
        var segments: [MutableSegment] = []
        var current = MutableSegment()
        var lastAccepted: RouteSample?
        var lastOutput: RouteSample?
        var kalman = Kalman2D()

        for sample in precise {
            if let previous = lastAccepted,
               sample.timestamp.timeIntervalSince(previous.timestamp) > configuration.segmentGap {
                if !current.path.isEmpty { segments.append(current) }
                current = MutableSegment(isNewSegment: true)
                lastAccepted = nil
                lastOutput = nil
                kalman = Kalman2D()
            }

            guard let previous = lastAccepted, let previousOutput = lastOutput else {
                current.sources.append(sample)
                current.path.append(sample)
                lastAccepted = sample
                lastOutput = sample
                kalman = Kalman2D(initial: sample)
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .acceptedPath))
                continue
            }

            let elapsed = sample.timestamp.timeIntervalSince(previous.timestamp)
            guard elapsed > 0 else { continue }
            let displacement = Geo.distance(previousOutput.coordinate, sample.coordinate)
            let stationaryThreshold = max(
                configuration.stationaryRadiusMeters,
                min(8, sample.horizontalAccuracyMeters * 0.35)
            )
            let isStationary = sample.speedMetersPerSecond.map {
                $0.isFinite && $0 >= 0 && $0 <= configuration.stationarySpeedMetersPerSecond
            } ?? (displacement <= stationaryThreshold)
            if displacement <= stationaryThreshold, isStationary {
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .stationarySuppressed))
                continue
            }

            let allowance = 3 * hypot(previous.horizontalAccuracyMeters, sample.horizontalAccuracyMeters)
            let maximumSpeed = min(
                configuration.absoluteMaximumSpeedMetersPerSecond,
                max(modeSpeed(for: sample, previous: previous), reportedMaximumSpeed(previous, sample))
            )
            guard displacement <= max(25, maximumSpeed * elapsed + allowance) else {
                if !current.path.isEmpty { segments.append(current) }
                current = MutableSegment(isNewSegment: true)
                lastAccepted = nil
                lastOutput = nil
                kalman = Kalman2D()
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .impossibleSpeed))
                continue
            }

            guard let output = kalman.update(
                measurement: sample,
                processAcceleration: configuration.processAccelerationNoise,
                innovationGate: configuration.innovationGate
            ) else {
                if !current.path.isEmpty { segments.append(current) }
                current = MutableSegment(isNewSegment: true)
                lastAccepted = nil
                lastOutput = nil
                kalman = Kalman2D()
                decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .innovationOutlier))
                continue
            }
            current.sources.append(sample)
            current.path.append(output)
            lastAccepted = sample
            lastOutput = output
            decisions.append(.init(id: sample.id, timestamp: sample.timestamp, reason: .acceptedPath))
        }
        if !current.path.isEmpty { segments.append(current) }

        return .init(
            log: RouteLog(
                segments: attach(boundaries: boundaries, to: segments),
                normalizedSamples: normalized
            ),
            decisions: decisions.sorted(by: Self.decisionOrder)
        )
    }

    public static func normalizeDuplicates(_ samples: [RouteSample]) -> [RouteSample] {
        let sorted = samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return tieBreak(lhs, rhs)
        }
        var result: [RouteSample] = []
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count, sorted[end].timestamp == sorted[index].timestamp { end += 1 }
            if let selected = sorted[index..<end].min(by: tieBreak) { result.append(selected) }
            index = end
        }
        return result
    }

    private func boundarySamples(from normalized: [RouteSample]) -> [RouteSample] {
        var result: [RouteSample] = []
        var index = 0
        while index < normalized.count {
            guard !normalized[index].isPrecisePathSample(configuration) else {
                index += 1
                continue
            }
            let start = index
            while index < normalized.count,
                  !normalized[index].isPrecisePathSample(configuration) {
                index += 1
            }
            result.append(normalized[start])
            if index - 1 > start { result.append(normalized[index - 1]) }
        }
        return result
    }

    private func attach(
        boundaries: [RouteSample],
        to segments: [MutableSegment]
    ) -> [RouteSegment] {
        guard !segments.isEmpty else {
            guard let first = boundaries.first, let last = boundaries.last else { return [] }
            return [RouteSegment(
                start: first.timestamp,
                end: last.timestamp,
                mode: boundaries.first(where: { $0.mode != .unknown })?.mode ?? .unknown,
                samples: boundaries,
                pathSamples: [],
                boundarySamples: boundaries,
                isLowConfidence: true
            )]
        }
        var assigned = Array(repeating: [RouteSample](), count: segments.count)
        for boundary in boundaries {
            let index = segments.indices.min { lhs, rhs in
                distance(from: boundary.timestamp, to: segments[lhs])
                    < distance(from: boundary.timestamp, to: segments[rhs])
            } ?? 0
            assigned[index].append(boundary)
        }
        return segments.indices.map { index in
            let segment = segments[index]
            let boundary = assigned[index].sorted(by: Self.sampleOrder)
            let sources = (segment.sources + boundary).sorted(by: Self.sampleOrder)
            return RouteSegment(
                start: sources.first?.timestamp ?? segment.path[0].timestamp,
                end: sources.last?.timestamp ?? segment.path[segment.path.count - 1].timestamp,
                mode: sources.first(where: { $0.mode != .unknown })?.mode ?? .unknown,
                samples: sources,
                pathSamples: segment.path,
                boundarySamples: boundary,
                isNewSegment: segment.isNewSegment || index > 0,
                isLowConfidence: !boundary.isEmpty,
                subwayEvidence: nil
            )
        }
    }

    private func distance(from timestamp: Date, to segment: MutableSegment) -> TimeInterval {
        guard let first = segment.path.first?.timestamp,
              let last = segment.path.last?.timestamp else { return .greatestFiniteMagnitude }
        if timestamp < first { return first.timeIntervalSince(timestamp) }
        if timestamp > last { return timestamp.timeIntervalSince(last) }
        return 0
    }

    private func modeSpeed(for sample: RouteSample, previous: RouteSample) -> Double {
        let mode = sample.mode == .unknown ? previous.mode : sample.mode
        return mode == .unknown
            ? configuration.maximumUnknownSpeedMetersPerSecond
            : mode.maximumSpeedMetersPerSecond
    }

    private func reportedMaximumSpeed(_ lhs: RouteSample, _ rhs: RouteSample) -> Double {
        [lhs, rhs].compactMap { sample -> Double? in
            guard let speed = sample.speedMetersPerSecond,
                  speed.isFinite, speed >= 0 else { return nil }
            let accuracy = sample.speedAccuracyMetersPerSecond ?? 0
            guard accuracy.isFinite, accuracy >= 0 else { return nil }
            return speed + 3 * accuracy
        }.max() ?? 0
    }

    private static func tieBreak(_ lhs: RouteSample, _ rhs: RouteSample) -> Bool {
        let leftPrecise = lhs.isPrecise && !lhs.isApproximate
        let rightPrecise = rhs.isPrecise && !rhs.isApproximate
        if leftPrecise != rightPrecise { return leftPrecise }
        if lhs.horizontalAccuracyMeters != rhs.horizontalAccuracyMeters {
            return lhs.horizontalAccuracyMeters < rhs.horizontalAccuracyMeters
        }
        if lhs.sequence != rhs.sequence {
            return (lhs.sequence ?? .min) > (rhs.sequence ?? .min)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sampleOrder(_ lhs: RouteSample, _ rhs: RouteSample) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func decisionOrder(_ lhs: RouteSampleDecision, _ rhs: RouteSampleDecision) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct MutableSegment {
    var sources: [RouteSample] = []
    var path: [RouteSample] = []
    var isNewSegment: Bool

    init(isNewSegment: Bool = false) {
        self.isNewSegment = isNewSegment
    }
}

private extension RouteSample {
    func isPrecisePathSample(_ configuration: RouteLoggerRouteFilterConfiguration) -> Bool {
        !isApproximate
            && horizontalAccuracyMeters >= 0
            && horizontalAccuracyMeters <= configuration.maximumAccuracyForPathMeters
    }
}

private enum Geo {
    static let metersPerDegree = 111_320.0

    static func distance(_ lhs: RouteCoordinate, _ rhs: RouteCoordinate) -> Double {
        let latitude = (lhs.latitude + rhs.latitude) * .pi / 360
        let north = (rhs.latitude - lhs.latitude) * metersPerDegree
        let east = (rhs.longitude - lhs.longitude) * metersPerDegree * cos(latitude)
        return hypot(north, east)
    }

    static func project(_ coordinate: RouteCoordinate, latitude: Double) -> (x: Double, y: Double) {
        (coordinate.longitude * metersPerDegree * cos(latitude * .pi / 180), coordinate.latitude * metersPerDegree)
    }

    static func unproject(_ point: (x: Double, y: Double), latitude: Double) -> RouteCoordinate {
        RouteCoordinate(
            latitude: point.y / metersPerDegree,
            longitude: point.x / (metersPerDegree * cos(latitude * .pi / 180))
        )
    }
}

private struct Kalman2D {
    private var state: (x: Double, y: Double, vx: Double, vy: Double)?
    private var positionVariance = 25.0
    private var positionVelocityCovariance = 0.0
    private var velocityVariance = 25.0
    private var timestamp: Date?
    private var latitude = 0.0

    init(initial: RouteSample? = nil) {
        if let initial { initialize(initial) }
    }

    mutating func update(
        measurement: RouteSample,
        processAcceleration: Double,
        innovationGate: Double
    ) -> RouteSample? {
        guard state != nil else {
            initialize(measurement)
            return measurement
        }
        let point = Geo.project(measurement.coordinate, latitude: latitude)
        let dt = max(0.001, measurement.timestamp.timeIntervalSince(timestamp ?? measurement.timestamp))
        var current = state!
        current.x += current.vx * dt
        current.y += current.vy * dt
        let q = max(0, processAcceleration) * max(0, processAcceleration)
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt2 * dt2
        let predictedPositionVariance = positionVariance
            + 2 * dt * positionVelocityCovariance
            + dt2 * velocityVariance
            + dt4 * q / 4
        let predictedCovariance = positionVelocityCovariance
            + dt * velocityVariance
            + dt3 * q / 2
        let predictedVelocityVariance = velocityVariance + dt2 * q
        let variance = max(25, measurement.horizontalAccuracyMeters * measurement.horizontalAccuracyMeters)
        let innovationVariance = max(0.001, predictedPositionVariance + variance)
        let innovationX = point.x - current.x
        let innovationY = point.y - current.y
        let normalizedInnovationSquared = (
            innovationX * innovationX + innovationY * innovationY
        ) / innovationVariance
        guard normalizedInnovationSquared <= max(0.01, innovationGate) else { return nil }

        let positionGain = predictedPositionVariance / innovationVariance
        let velocityGain = predictedCovariance / innovationVariance
        current.x += positionGain * innovationX
        current.y += positionGain * innovationY
        current.vx += velocityGain * innovationX
        current.vy += velocityGain * innovationY
        positionVariance = max(0.001, (1 - positionGain) * predictedPositionVariance)
        positionVelocityCovariance = (1 - positionGain) * predictedCovariance
        velocityVariance = max(0.001, predictedVelocityVariance - velocityGain * predictedCovariance)
        state = current
        timestamp = measurement.timestamp
        return RouteSample(
            id: measurement.id,
            timestamp: measurement.timestamp,
            coordinate: Geo.unproject((current.x, current.y), latitude: latitude),
            horizontalAccuracyMeters: max(measurement.horizontalAccuracyMeters, sqrt(positionVariance)),
            speedMetersPerSecond: measurement.speedMetersPerSecond,
            speedAccuracyMetersPerSecond: measurement.speedAccuracyMetersPerSecond,
            sequence: measurement.sequence,
            mode: measurement.mode,
            isApproximate: measurement.isApproximate
        )
    }

    private mutating func initialize(_ measurement: RouteSample) {
        latitude = measurement.coordinate.latitude
        let point = Geo.project(measurement.coordinate, latitude: latitude)
        state = (point.x, point.y, 0, 0)
        positionVariance = max(25, measurement.horizontalAccuracyMeters * measurement.horizontalAccuracyMeters)
        positionVelocityCovariance = 0
        velocityVariance = 25
        timestamp = measurement.timestamp
    }
}
