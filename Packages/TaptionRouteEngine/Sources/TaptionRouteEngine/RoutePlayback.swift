import Foundation

public enum RoutePlaybackDirection: Int, CaseIterable, Codable, Hashable, Sendable {
    case north
    case northeast
    case east
    case southeast
    case south
    case southwest
    case west
    case northwest
}

public struct RoutePlaybackSample: Hashable, Sendable {
    public let coordinate: RouteCoordinate
    public let progress: Double
    public let distanceMeters: Double
    public let direction: RoutePlaybackDirection
    public let frameIndex: Int

    public init(
        coordinate: RouteCoordinate,
        progress: Double,
        distanceMeters: Double,
        direction: RoutePlaybackDirection,
        frameIndex: Int
    ) {
        self.coordinate = coordinate
        self.progress = progress
        self.distanceMeters = distanceMeters
        self.direction = direction
        self.frameIndex = frameIndex
    }
}

/// Immutable cumulative-distance playback index. The line and its marker use
/// the same sampled coordinate, so a renderer cannot drift between them.
public struct RoutePlaybackProjection: Hashable, Sendable {
    public let coordinates: [RouteCoordinate]
    public let cumulativeDistances: [Double]
    public let totalDistanceMeters: Double

    public init(coordinates: [RouteCoordinate]) {
        let valid = coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        self.coordinates = valid
        var distances = [Double](repeating: 0, count: valid.count)
        for index in valid.indices.dropFirst() {
            distances[index] = distances[index - 1]
                + Self.distanceMeters(valid[index - 1], valid[index])
        }
        cumulativeDistances = distances
        totalDistanceMeters = distances.last ?? 0
    }

    public var isEmpty: Bool { coordinates.isEmpty }

    public func sample(
        progress rawProgress: Double,
        lookAheadFraction: Double = 0.01,
        frameCount: Int = 24
    ) -> RoutePlaybackSample? {
        guard let first = coordinates.first else { return nil }
        let progress = min(1, max(0, rawProgress.isFinite ? rawProgress : 0))
        let distance = totalDistanceMeters * progress
        let position = coordinate(atDistance: distance) ?? first
        let lookAheadDistance = min(
            totalDistanceMeters,
            distance + totalDistanceMeters * max(0, lookAheadFraction)
        )
        let lookAhead = coordinate(atDistance: lookAheadDistance) ?? position
        let direction = Self.direction(from: position, to: lookAhead)
        let safeFrameCount = max(1, frameCount)
        let frameIndex = min(safeFrameCount - 1, Int(floor(progress * Double(safeFrameCount))))
        return RoutePlaybackSample(
            coordinate: position,
            progress: progress,
            distanceMeters: distance,
            direction: direction,
            frameIndex: frameIndex
        )
    }

    private func coordinate(atDistance distance: Double) -> RouteCoordinate? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1, totalDistanceMeters > 0 else { return first }
        let target = min(totalDistanceMeters, max(0, distance))
        guard let upper = cumulativeDistances.firstIndex(where: { $0 >= target }) else {
            return coordinates.last
        }
        guard upper > 0 else { return coordinates[0] }
        let lower = upper - 1
        let span = cumulativeDistances[upper] - cumulativeDistances[lower]
        let fraction = span > 0
            ? (target - cumulativeDistances[lower]) / span
            : 0
        let start = coordinates[lower]
        let end = coordinates[upper]
        return RouteCoordinate(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func direction(
        from start: RouteCoordinate,
        to end: RouteCoordinate
    ) -> RoutePlaybackDirection {
        let latitude = (start.latitude + end.latitude) * .pi / 360
        let dx = (end.longitude - start.longitude) * cos(latitude)
        let dy = end.latitude - start.latitude
        guard dx != 0 || dy != 0 else { return .north }
        let bearing = atan2(dx, dy) * 180 / .pi
        let slot = Int(floor((bearing + 22.5 + 360).truncatingRemainder(dividingBy: 360) / 45)) % 8
        return RoutePlaybackDirection(rawValue: slot) ?? .north
    }

    private static func distanceMeters(
        _ lhs: RouteCoordinate,
        _ rhs: RouteCoordinate
    ) -> Double {
        let latitude = (lhs.latitude + rhs.latitude) * .pi / 360
        let metersPerDegree = 111_320.0
        let dx = (rhs.longitude - lhs.longitude) * metersPerDegree * cos(latitude)
        let dy = (rhs.latitude - lhs.latitude) * metersPerDegree
        return (dx * dx + dy * dy).squareRoot()
    }
}
