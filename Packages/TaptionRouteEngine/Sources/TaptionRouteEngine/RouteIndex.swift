import Foundation

public struct RouteTimeCoordinateIndex: Sendable {
    private let segments: [[RouteSample]]
    private let segmentStartTimes: [Date]
    private let prefixMaximumEndTimes: [Date]
    private let firstSample: RouteSample?
    private let lastSample: RouteSample?

    public init(samples: [RouteSample]) {
        self.init(segments: [samples], cancellationCheck: {})
    }

    public init(
        samples: [RouteSample],
        cancellationCheck: () throws -> Void
    ) rethrows {
        try self.init(segments: [samples], cancellationCheck: cancellationCheck)
    }

    public init(segments: [[RouteSample]]) {
        self.init(segments: segments, cancellationCheck: {})
    }

    public init(
        segments input: [[RouteSample]],
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        var segments: [[RouteSample]] = []
        segments.reserveCapacity(input.count)
        for (segmentIndex, samples) in input.enumerated() {
            if segmentIndex.isMultiple(of: 32) { try cancellationCheck() }
            var finiteSamples: [RouteSample] = []
            finiteSamples.reserveCapacity(samples.count)
            for (sampleIndex, sample) in samples.enumerated() {
                if sampleIndex.isMultiple(of: 256) { try cancellationCheck() }
                guard RouteTimestamp.isValid(sample.timestamp) else { continue }
                finiteSamples.append(sample)
            }
            let sorted = try RouteCancellableSort.sorted(
                finiteSamples,
                by: { $0.timestamp < $1.timestamp },
                cancellationCheck: cancellationCheck
            )
            if !sorted.isEmpty { segments.append(sorted) }
        }
        segments = try RouteCancellableSort.sorted(
            segments,
            by: Self.precedes,
            cancellationCheck: cancellationCheck
        )
        self.segments = segments

        var starts: [Date] = []
        var maximumEnds: [Date] = []
        starts.reserveCapacity(segments.count)
        maximumEnds.reserveCapacity(segments.count)
        var maximumEnd: Date?
        var latestSample: RouteSample?
        for (index, samples) in segments.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let start = samples.first?.timestamp,
                  let end = samples.last?.timestamp else { continue }
            starts.append(start)
            maximumEnd = maximumEnd.map { max($0, end) } ?? end
            maximumEnds.append(maximumEnd ?? end)
            if latestSample.map({ $0.timestamp < end }) ?? true {
                latestSample = samples.last
            }
        }
        segmentStartTimes = starts
        prefixMaximumEndTimes = maximumEnds
        firstSample = segments.first?.first
        lastSample = latestSample
    }

    private static func precedes(_ lhs: [RouteSample], _ rhs: [RouteSample]) -> Bool {
        let lhsStart = lhs[0].timestamp
        let rhsStart = rhs[0].timestamp
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        for (left, right) in zip(lhs, rhs) where left.id != right.id {
            return uuidPrecedes(left.id, right.id)
        }
        return lhs.count < rhs.count
    }

    private static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { lhsBytes in
            withUnsafeBytes(of: rhs.uuid) { rhsBytes in
                for index in 0..<16 where lhsBytes[index] != rhsBytes[index] {
                    return lhsBytes[index] < rhsBytes[index]
                }
                return false
            }
        }
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func sample(at date: Date) -> RouteSample? {
        guard RouteTimestamp.isValid(date) else { return nil }
        guard let first = firstSample,
              let last = lastSample else { return nil }
        guard date > first.timestamp else { return first }
        guard date < last.timestamp else { return last }

        var upperBound = 0
        var upperLimit = segmentStartTimes.count
        while upperBound < upperLimit {
            let middle = (upperBound + upperLimit) / 2
            if segmentStartTimes[middle] <= date {
                upperBound = middle + 1
            } else {
                upperLimit = middle
            }
        }
        guard upperBound > 0 else { return nil }

        var lowerBound = 0
        var lowerLimit = upperBound
        while lowerBound < lowerLimit {
            let middle = (lowerBound + lowerLimit) / 2
            if prefixMaximumEndTimes[middle] < date {
                lowerBound = middle + 1
            } else {
                lowerLimit = middle
            }
        }
        guard lowerBound < upperBound else { return nil }
        return sample(at: date, in: segments[lowerBound])
    }

    private func sample(at date: Date, in samples: [RouteSample]) -> RouteSample? {
        guard let first = samples.first,
              let last = samples.last else { return nil }
        if date <= first.timestamp { return first }
        if date >= last.timestamp { return last }
        var lower = 0
        var upper = samples.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if samples[middle].timestamp <= date { lower = middle } else { upper = middle }
        }
        let lhs = samples[lower]
        let rhs = samples[upper]
        let duration = rhs.timestamp.timeIntervalSince(lhs.timestamp)
        guard duration > 0 else { return lhs }
        let fraction = date.timeIntervalSince(lhs.timestamp) / duration
        return RouteSample(
            timestamp: date,
            coordinate: RouteCoordinate(
                latitude: lhs.coordinate.latitude + (rhs.coordinate.latitude - lhs.coordinate.latitude) * fraction,
                longitude: RouteLongitude.interpolate(
                    from: lhs.coordinate.longitude,
                    to: rhs.coordinate.longitude,
                    fraction: fraction
                )
            ),
            horizontalAccuracyMeters: max(lhs.horizontalAccuracyMeters, rhs.horizontalAccuracyMeters),
            speedMetersPerSecond: lhs.speedMetersPerSecond,
            mode: lhs.mode
        )
    }
}

public enum RoutePathSimplifier {
    private static let maximumFullDouglasPeuckerInputCount = 1_600
    private static let maximumDouglasPeuckerCandidates = 512

    public static func simplify(_ points: [RouteCoordinate], toleranceMeters: Double = 5, maximumCount: Int = 4_096) -> [RouteCoordinate] {
        simplify(
            points,
            toleranceMeters: toleranceMeters,
            maximumCount: maximumCount,
            cancellationCheck: {}
        )
    }

    public static func simplify(
        _ points: [RouteCoordinate],
        toleranceMeters: Double = 5,
        maximumCount: Int = 4_096,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RouteCoordinate] {
        try cancellationCheck()
        guard points.count > 2 else { return points }
        let maximumCount = max(2, maximumCount)
        guard maximumCount > 2 else {
            return [points[0], points[points.count - 1]]
        }

        var operations = 0
        func checkWork() throws {
            operations += 1
            if operations.isMultiple(of: 256) {
                try cancellationCheck()
            }
        }

        let projected = try projectedPoints(points, checkWork: checkWork)
        let tolerance = max(0, toleranceMeters)
        let toleranceSquared = tolerance * tolerance
        let first = projected[0]
        let last = projected[projected.count - 1]
        var isStraightWithinTolerance = true
        for point in projected.dropFirst().dropLast() {
            try checkWork()
            if perpendicularSquared(point, first, last) > toleranceSquared {
                isStraightWithinTolerance = false
                break
            }
        }
        if isStraightWithinTolerance {
            return [points[0], points[points.count - 1]]
        }

        if points.count <= maximumFullDouglasPeuckerInputCount {
            let simplified = try douglasPeuckerIndices(
                Array(projected.indices),
                in: projected,
                toleranceSquared: toleranceSquared,
                checkWork: checkWork
            )
            if simplified.count <= maximumCount {
                return simplified.map { points[$0] }
            }
        }

        let radial = try radialDistanceIndices(
            projected,
            toleranceSquared: toleranceSquared,
            checkWork: checkWork
        )
        let candidates = radial.count > maximumCount
            ? try boundedDeviationIndices(
                projected,
                maximumCount: maximumCount,
                toleranceSquared: toleranceSquared,
                checkWork: checkWork
            )
            : radial
        guard candidates.count <= maximumDouglasPeuckerCandidates else {
            return candidates.map { points[$0] }
        }
        let indices = try douglasPeuckerIndices(
            candidates,
            in: projected,
            toleranceSquared: toleranceSquared,
            checkWork: checkWork
        )
        return indices.map { points[$0] }
    }

    private static func projectedPoints(
        _ points: [RouteCoordinate],
        checkWork: () throws -> Void
    ) rethrows -> [(x: Double, y: Double)] {
        var latitudeSum = 0.0
        for point in points {
            try checkWork()
            latitudeSum += point.latitude
        }
        let latitude = latitudeSum / Double(points.count)
        var projected: [(x: Double, y: Double)] = []
        projected.reserveCapacity(points.count)
        let longitudeScale = 111_320 * cos(latitude * .pi / 180)
        let originLongitude = points[0].longitude
        for point in points {
            try checkWork()
            projected.append((
                x: RouteLongitude.shortestDelta(from: originLongitude, to: point.longitude) * longitudeScale,
                y: point.latitude * 111_320
            ))
        }
        return projected
    }

    private static func radialDistanceIndices(
        _ points: [(x: Double, y: Double)],
        toleranceSquared: Double,
        checkWork: () throws -> Void
    ) rethrows -> [Int] {
        var indices = [0]
        var anchor = points[0]
        for index in 1..<(points.count - 1) {
            try checkWork()
            let point = points[index]
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            if dx * dx + dy * dy > toleranceSquared {
                indices.append(index)
                anchor = point
            }
        }
        indices.append(points.count - 1)
        return indices
    }

    private static func douglasPeuckerIndices(
        _ candidates: [Int],
        in points: [(x: Double, y: Double)],
        toleranceSquared: Double,
        checkWork: () throws -> Void
    ) rethrows -> [Int] {
        guard candidates.count > 2 else { return candidates }
        var keep = [Bool](repeating: false, count: candidates.count)
        keep[0] = true
        keep[keep.count - 1] = true
        var stack = [(0, candidates.count - 1)]

        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let start = points[candidates[first]]
            let end = points[candidates[last]]
            var farthest = first
            var farthestDistance = -1.0
            for candidateIndex in (first + 1)..<last {
                try checkWork()
                let distance = perpendicularSquared(
                    points[candidates[candidateIndex]],
                    start,
                    end
                )
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = candidateIndex
                }
            }
            guard farthestDistance > toleranceSquared else { continue }
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }

        return keep.indices.compactMap { keep[$0] ? candidates[$0] : nil }
    }

    private static func boundedDeviationIndices(
        _ points: [(x: Double, y: Double)],
        maximumCount: Int,
        toleranceSquared: Double,
        checkWork: () throws -> Void
    ) rethrows -> [Int] {
        let slots = maximumCount - 2
        guard slots > 0 else { return [0, points.count - 1] }

        let interiorCount = points.count - 2
        var indices = [0]
        indices.reserveCapacity(maximumCount)
        for slot in 0..<slots {
            let start = 1 + slot * interiorCount / slots
            let end = 1 + (slot + 1) * interiorCount / slots
            let a = points[start - 1]
            let b = points[end]
            var farthestIndex = start
            var farthestDistance = -1.0
            for index in start..<end {
                try checkWork()
                let distance = perpendicularSquared(points[index], a, b)
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestIndex = index
                }
            }
            let selected = farthestDistance > toleranceSquared
                ? farthestIndex
                : start + (end - start - 1) / 2
            indices.append(selected)
        }
        indices.append(points.count - 1)
        return indices
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
