import Foundation
import TaptionPlanCore

public struct RouteLoggerRouteFilterConfiguration: Sendable {
    public var stationaryRadiusMeters: Double
    public var segmentGap: TimeInterval
    public var maximumAccuracyForPathMeters: Double
    public var processAccelerationNoise: Double

    public init(
        stationaryRadiusMeters: Double = 3,
        segmentGap: TimeInterval = 15 * 60,
        maximumAccuracyForPathMeters: Double = 150,
        processAccelerationNoise: Double = 4
    ) {
        self.stationaryRadiusMeters = stationaryRadiusMeters
        self.segmentGap = segmentGap
        self.maximumAccuracyForPathMeters = maximumAccuracyForPathMeters
        self.processAccelerationNoise = processAccelerationNoise
    }
}

public struct RouteLoggerRouteFilter: Sendable {
    public let configuration: RouteLoggerRouteFilterConfiguration

    public init(configuration: RouteLoggerRouteFilterConfiguration = .init()) {
        self.configuration = configuration
    }

    public func filter(_ input: [RouteSample]) -> RouteLog {
        let normalized = Self.normalizeDuplicates(input.filter(\.isUsable))
        guard !normalized.isEmpty else { return RouteLog(segments: [], normalizedSamples: []) }

        var segments: [RouteSegment] = []
        var current: [RouteSample] = []
        var filtered: [RouteSample] = []
        var anchor: RouteCoordinate?
        var previous: RouteSample?
        var kalman = Kalman2D()

        for sample in normalized {
            if let previous,
               sample.timestamp.timeIntervalSince(previous.timestamp) > configuration.segmentGap {
                if let segment = makeSegment(current, filtered: filtered, first: segments.isEmpty) { segments.append(segment) }
                current.removeAll(keepingCapacity: true)
                filtered.removeAll(keepingCapacity: true)
                anchor = nil
                kalman = Kalman2D()
            }

            if let previous,
               let maximumJump = maximumAllowedDistance(from: previous, to: sample),
               Geo.distance(previous.coordinate, sample.coordinate) > maximumJump {
                if let segment = makeSegment(current, filtered: filtered, first: segments.isEmpty) { segments.append(segment) }
                current.removeAll(keepingCapacity: true)
                filtered.removeAll(keepingCapacity: true)
                anchor = nil
                kalman = Kalman2D()
            }

            if anchor == nil,
               sample.speedMetersPerSecond ?? 0 < 0.5,
               let previousOutput = filtered.last,
               Geo.distance(previousOutput.coordinate, sample.coordinate)
                    <= configuration.stationaryRadiusMeters {
                anchor = previousOutput.coordinate
            }

            let output: RouteSample
            if let anchor,
               Geo.distance(anchor, sample.coordinate) <= configuration.stationaryRadiusMeters {
                output = RouteSample(
                    id: sample.id,
                    timestamp: sample.timestamp,
                    coordinate: anchor,
                    horizontalAccuracyMeters: sample.horizontalAccuracyMeters,
                    speedMetersPerSecond: 0,
                    speedAccuracyMetersPerSecond: sample.speedAccuracyMetersPerSecond,
                    sequence: sample.sequence,
                    mode: sample.mode,
                    isApproximate: sample.isApproximate
                )
            } else {
                if anchor != nil { anchor = nil }
                output = kalman.update(measurement: sample, noise: configuration.processAccelerationNoise)
            }
            if anchor == nil,
               output.speedMetersPerSecond ?? 0 < 0.5,
               let previousOutput = filtered.last,
               Geo.distance(previousOutput.coordinate, output.coordinate) <= configuration.stationaryRadiusMeters {
                anchor = previousOutput.coordinate
            }
            current.append(sample)
            filtered.append(output)
            previous = sample
        }
        if let segment = makeSegment(current, filtered: filtered, first: segments.isEmpty) { segments.append(segment) }
        return RouteLog(segments: segments, normalizedSamples: normalized)
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
            while end < sorted.count && sorted[end].timestamp == sorted[index].timestamp { end += 1 }
            if let selected = sorted[index..<end].sorted(by: tieBreak).first { result.append(selected) }
            index = end
        }
        return result
    }

    private static func tieBreak(_ lhs: RouteSample, _ rhs: RouteSample) -> Bool {
        if lhs.isPrecise != rhs.isPrecise { return lhs.isPrecise }
        let leftAccuracy = lhs.horizontalAccuracyMeters >= 0 ? lhs.horizontalAccuracyMeters : .infinity
        let rightAccuracy = rhs.horizontalAccuracyMeters >= 0 ? rhs.horizontalAccuracyMeters : .infinity
        if leftAccuracy != rightAccuracy { return leftAccuracy < rightAccuracy }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? .min) > (rhs.sequence ?? .min) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func maximumAllowedDistance(from lhs: RouteSample, to rhs: RouteSample) -> Double? {
        let elapsed = rhs.timestamp.timeIntervalSince(lhs.timestamp)
        guard elapsed > 0 else { return 0 }
        let mode = rhs.mode == .unknown ? lhs.mode : rhs.mode
        let reported = [lhs.speedMetersPerSecond, rhs.speedMetersPerSecond, lhs.speedAccuracyMetersPerSecond.map { $0 + (lhs.speedMetersPerSecond ?? 0) }, rhs.speedAccuracyMetersPerSecond.map { $0 + (rhs.speedMetersPerSecond ?? 0) }].compactMap { $0 }.max()
        let speed = min(120, max(mode.maximumSpeedMetersPerSecond, reported ?? 0))
        let uncertainty = max(0, lhs.horizontalAccuracyMeters) + max(0, rhs.horizontalAccuracyMeters)
        return speed * elapsed + uncertainty
    }

    private func makeSegment(_ samples: [RouteSample], filtered: [RouteSample]? = nil, first: Bool) -> RouteSegment? {
        guard let firstSample = samples.first, let lastSample = samples.last else { return nil }
        let output = filtered ?? samples
        let pathSamples = zip(samples, output).compactMap { source, value in
            source.horizontalAccuracyMeters < 0 || source.horizontalAccuracyMeters <= configuration.maximumAccuracyForPathMeters ? value : nil
        }
        let boundarySamples = zip(samples, output).compactMap { source, value in
            source.horizontalAccuracyMeters > configuration.maximumAccuracyForPathMeters
                && source.horizontalAccuracyMeters <= 1_000 ? value : nil
        }
        let mode = samples.first(where: { $0.mode != .unknown })?.mode ?? .unknown
        return RouteSegment(
            start: firstSample.timestamp,
            end: lastSample.timestamp,
            mode: mode,
            samples: samples,
            pathSamples: pathSamples,
            boundarySamples: boundarySamples,
            isNewSegment: !first,
            isLowConfidence: pathSamples.isEmpty || !boundarySamples.isEmpty || samples.contains { $0.horizontalAccuracyMeters > 1_000 },
            subwayEvidence: nil
        )
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
        RouteCoordinate(latitude: point.y / metersPerDegree, longitude: point.x / (metersPerDegree * cos(latitude * .pi / 180)))
    }
}

private struct Kalman2D {
    private var state: (x: Double, y: Double, vx: Double, vy: Double)?
    private var positionVariance = 25.0
    private var positionVelocityCovariance = 0.0
    private var velocityVariance = 25.0
    private var timestamp: Date?
    private var latitude = 0.0

    mutating func update(measurement: RouteSample, noise: Double) -> RouteSample {
        if state == nil {
            latitude = measurement.coordinate.latitude
            let point = Geo.project(measurement.coordinate, latitude: latitude)
            state = (point.x, point.y, 0, 0)
            positionVariance = max(
                25,
                measurement.horizontalAccuracyMeters
                    * measurement.horizontalAccuracyMeters
            )
            positionVelocityCovariance = 0
            velocityVariance = 25
            timestamp = measurement.timestamp
            return measurement
        }
        let point = Geo.project(measurement.coordinate, latitude: latitude)
        let dt = max(0.001, measurement.timestamp.timeIntervalSince(timestamp ?? measurement.timestamp))
        var current = state!
        current.x += current.vx * dt
        current.y += current.vy * dt
        let q = max(0, noise) * max(0, noise)
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
        let positionGain = predictedPositionVariance / innovationVariance
        let velocityGain = predictedCovariance / innovationVariance
        current.x += positionGain * innovationX
        current.y += positionGain * innovationY
        current.vx += velocityGain * innovationX
        current.vy += velocityGain * innovationY
        positionVariance = max(
            0.001,
            (1 - positionGain) * predictedPositionVariance
        )
        positionVelocityCovariance =
            (1 - positionGain) * predictedCovariance
        velocityVariance = max(
            0.001,
            predictedVelocityVariance - velocityGain * predictedCovariance
        )
        state = current
        timestamp = measurement.timestamp
        return RouteSample(
            id: measurement.id,
            timestamp: measurement.timestamp,
            coordinate: Geo.unproject((current.x, current.y), latitude: latitude),
            horizontalAccuracyMeters: measurement.horizontalAccuracyMeters,
            speedMetersPerSecond: measurement.speedMetersPerSecond,
            speedAccuracyMetersPerSecond: measurement.speedAccuracyMetersPerSecond,
            sequence: measurement.sequence,
            mode: measurement.mode,
            isApproximate: measurement.isApproximate
        )
    }
}
