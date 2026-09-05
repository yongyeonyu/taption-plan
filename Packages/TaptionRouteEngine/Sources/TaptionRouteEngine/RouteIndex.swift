import Foundation

public struct RouteTimeCoordinateIndex: Sendable {
    private let samples: [RouteSample]

    public init(samples: [RouteSample]) {
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
    }

    public var isEmpty: Bool { samples.isEmpty }

    public func sample(at date: Date) -> RouteSample? {
        guard let first = samples.first else { return nil }
        guard date > first.timestamp else { return first }
        guard let last = samples.last else { return first }
        guard date < last.timestamp else { return last }
        var lower = 0
        var upper = samples.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if samples[middle].timestamp <= date { lower = middle } else { upper = middle }
        }
        let lhs = samples[lower]
        let rhs = samples[upper]
        let fraction = date.timeIntervalSince(lhs.timestamp) / rhs.timestamp.timeIntervalSince(lhs.timestamp)
        return RouteSample(
            timestamp: date,
            coordinate: RouteCoordinate(
                latitude: lhs.coordinate.latitude + (rhs.coordinate.latitude - lhs.coordinate.latitude) * fraction,
                longitude: lhs.coordinate.longitude + (rhs.coordinate.longitude - lhs.coordinate.longitude) * fraction
            ),
            horizontalAccuracyMeters: max(lhs.horizontalAccuracyMeters, rhs.horizontalAccuracyMeters),
            speedMetersPerSecond: lhs.speedMetersPerSecond,
            mode: lhs.mode
        )
    }
}

public enum RoutePathSimplifier {
    public static func simplify(_ points: [RouteCoordinate], toleranceMeters: Double = 5, maximumCount: Int = 4_096) -> [RouteCoordinate] {
        guard points.count > 2 else { return points }
        let maximumCount = max(2, maximumCount)
        var tolerance = max(0, toleranceMeters)
        let boundedInput: [RouteCoordinate]
        if points.count > maximumCount * 2 {
            let step = Int(ceil(Double(points.count - 1) / Double(maximumCount * 2 - 1)))
            boundedInput = Array(Swift.stride(from: 0, through: points.count - 1, by: max(1, step))).map { points[$0] } + [points[points.count - 1]]
        } else {
            boundedInput = points
        }
        var result = rdp(boundedInput, tolerance: tolerance)
        while result.count > maximumCount {
            tolerance = max(0.1, tolerance * 1.5)
            result = rdp(boundedInput, tolerance: tolerance)
        }
        return result
    }

    private static func rdp(_ points: [RouteCoordinate], tolerance: Double) -> [RouteCoordinate] {
        guard points.count > 2 else { return points }
        let latitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let projected = points.map { (x: $0.longitude * 111_320 * cos(latitude * .pi / 180), y: $0.latitude * 111_320) }
        var keep = Set([0, points.count - 1])
        var ranges = [(start: 0, end: points.count - 1)]
        while let range = ranges.popLast() {
            guard range.end > range.start + 1 else { continue }
            let a = projected[range.start]
            let b = projected[range.end]
            var index = -1
            var maximum = tolerance * tolerance
            for i in (range.start + 1)..<range.end {
                let distance = perpendicularSquared(projected[i], a, b)
                if distance > maximum { maximum = distance; index = i }
            }
            guard index >= 0 else { continue }
            keep.insert(index)
            ranges.append((range.start, index))
            ranges.append((index, range.end))
        }
        return points.indices.filter { keep.contains($0) }.map { points[$0] }
    }

    private static func perpendicularSquared(_ point: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 { return (point.x - a.x) * (point.x - a.x) + (point.y - a.y) * (point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
        let x = a.x + t * dx
        let y = a.y + t * dy
        return (point.x - x) * (point.x - x) + (point.y - y) * (point.y - y)
    }
}
