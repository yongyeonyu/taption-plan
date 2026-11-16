import Foundation
import CryptoKit
import TaptionPlanEngine

extension RouteTimelineDataEngine {
    private static func segmentAwareDisplayIndices(
        _ readings: [SensorReading],
        epsilon: Double,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Int] {
        try cancellationCheck()
        guard readings.count > 1 else { return readings.indices.map { $0 } }
        var result: [Int] = []
        var segmentStart = 0
        for index in 1..<readings.count {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if startsNewDisplaySegment(
                after: readings[index - 1],
                before: readings[index]
            ) {
                result.append(contentsOf: try rdpIndices(
                    readings,
                    lower: segmentStart,
                    upper: index - 1,
                    epsilon: epsilon,
                    cancellationCheck: cancellationCheck
                ))
                segmentStart = index
            }
        }
        result.append(contentsOf: try rdpIndices(
            readings,
            lower: segmentStart,
            upper: readings.count - 1,
            epsilon: epsilon,
            cancellationCheck: cancellationCheck
        ))
        return result
    }

    static func reducedDisplayIndices(
        _ readings: [SensorReading],
        maximumCount: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Int] {
        let mandatory = try mandatoryDisplayIndices(
            readings,
            cancellationCheck: cancellationCheck
        )
        func selected(at epsilon: Double) throws -> Set<Int> {
            let indices = try segmentAwareDisplayIndices(
                readings,
                epsilon: epsilon,
                cancellationCheck: cancellationCheck
            )
            var selected = Set<Int>()
            selected.reserveCapacity(mandatory.count + indices.count)
            for (index, value) in mandatory.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(value)
            }
            for (index, value) in indices.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(value)
            }
            return selected
        }

        var high = 4.0
        var highSelection = try selected(at: high)
        while highSelection.count > maximumCount, high < 1_000_000 {
            try cancellationCheck()
            high *= 2
            highSelection = try selected(at: high)
        }
        if highSelection.count > maximumCount {
            return try RouteTimelineCancellableSort.sorted(
                try RouteTimelineCancellableSort.collect(
                    mandatory,
                    cancellationCheck: cancellationCheck
                ),
                by: <,
                cancellationCheck: cancellationCheck
            )
        }

        var low = 0.0
        for _ in 0..<24 {
            try cancellationCheck()
            let middle = (low + high) / 2
            if try selected(at: middle).count > maximumCount {
                low = middle
            } else {
                high = middle
            }
        }
        highSelection = try selected(at: high)
        return try RouteTimelineCancellableSort.sorted(
            try RouteTimelineCancellableSort.collect(
                highSelection,
                cancellationCheck: cancellationCheck
            ),
            by: <,
            cancellationCheck: cancellationCheck
        )
    }

    private static func mandatoryDisplayIndices(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> Set<Int> {
        try cancellationCheck()
        guard !readings.isEmpty else { return [] }
        var result: Set<Int> = [readings.startIndex, readings.index(before: readings.endIndex)]
        guard readings.count > 2 else { return result }

        for index in 1..<readings.count {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if startsNewDisplaySegment(
                after: readings[index - 1],
                before: readings[index]
            ) {
                result.insert(index - 1)
                result.insert(index)
            }
        }

        for index in 1..<(readings.count - 1) {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let previous = readings[index - 1].point,
                  let current = readings[index].point,
                  let next = readings[index + 1].point else { continue }
            let first = displayMeterPoint(previous, origin: current)
            let third = displayMeterPoint(next, origin: current)
            let firstDistance = hypot(first.east, first.north)
            let thirdDistance = hypot(third.east, third.north)
            guard firstDistance >= 2, thirdDistance >= 2 else { continue }
            let dot = first.east * third.east + first.north * third.north
            let cross = first.east * third.north - first.north * third.east
            let angle = abs(atan2(cross, dot))
            if angle >= 15 * .pi / 180 {
                result.insert(index)
            }
        }
        return result
    }

    private static func startsNewDisplaySegment(
        after previous: SensorReading,
        before current: SensorReading
    ) -> Bool {
        if previous.trackingSessionEnded == true {
            return true
        }
        guard let previousPoint = previous.point,
              let currentPoint = current.point else { return true }
        let gap = current.timestamp.timeIntervalSince(previous.timestamp)
        guard gap > 0 else { return true }
        if gap > maximumInterpolationGap { return true }
        return RouteSparseConnectionPolicy.breaksConnection(
            gapDuration: gap,
            distanceMeters: gap
                    > RouteSparseConnectionPolicy.minimumSparseGapDuration
                ? distanceMeters(previousPoint, currentPoint)
                : nil
        )
    }

    private static func rdpIndices(
        _ readings: [SensorReading],
        lower: Int,
        upper: Int,
        epsilon: Double = 4,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Int] {
        try cancellationCheck()
        guard upper >= lower else { return [] }
        guard upper > lower else { return [lower] }
        let origin = readings[lower].point
        var coordinates: [DisplayMeterPoint] = []
        coordinates.reserveCapacity(upper - lower + 1)
        for (offset, index) in (lower...upper).enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            coordinates.append(displayMeterPoint(readings[index].point, origin: origin))
        }
        var retained = Set([lower, upper])
        var stack: [(start: Int, end: Int)] = [(0, upper - lower)]
        var comparisons = 0
        while let pair = stack.popLast() {
            if stack.count.isMultiple(of: 64) { try cancellationCheck() }
            guard pair.end - pair.start > 1 else { continue }
            let start = coordinates[pair.start]
            let end = coordinates[pair.end]
            var farthestOffset = -1
            var farthestDistance = epsilon
            for offset in (pair.start + 1)..<pair.end {
                comparisons += 1
                if comparisons.isMultiple(of: 256) { try cancellationCheck() }
                let distance = perpendicularDistance(
                    coordinates[offset],
                    from: start,
                    to: end
                )
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestOffset = offset
                }
            }
            guard farthestOffset >= 0 else { continue }
            retained.insert(lower + farthestOffset)
            stack.append((pair.start, farthestOffset))
            stack.append((farthestOffset, pair.end))
        }
        return try RouteTimelineCancellableSort.sorted(
            try RouteTimelineCancellableSort.collect(
                retained,
                cancellationCheck: cancellationCheck
            ),
            by: <,
            cancellationCheck: cancellationCheck
        )
    }

    private static func displayMeterPoint(
        _ point: GeoPoint?,
        origin: GeoPoint?
    ) -> DisplayMeterPoint {
        guard let point, let origin else {
            return DisplayMeterPoint(east: 0, north: 0)
        }
        let latitudeScale = 111_132.92
        let longitudeScale = max(
            1,
            111_412.84 * cos(origin.latitude * .pi / 180)
        )
        return DisplayMeterPoint(
            east: RouteTimelineLongitude.shortestDelta(
                from: origin.longitude,
                to: point.longitude
            ) * longitudeScale,
            north: (point.latitude - origin.latitude) * latitudeScale
        )
    }

    private static func perpendicularDistance(
        _ point: DisplayMeterPoint,
        from start: DisplayMeterPoint,
        to end: DisplayMeterPoint
    ) -> Double {
        let dx = end.east - start.east
        let dy = end.north - start.north
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.east - start.east, point.north - start.north)
        }
        let cross = abs(
            dx * (start.north - point.north)
                - (start.east - point.east) * dy
        )
        return cross / sqrt(lengthSquared)
    }

    static func evenlySampledIndices(
        _ indices: [Int],
        count: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Int] {
        try cancellationCheck()
        guard count > 1, indices.count > count else { return indices }
        let scale = Double(indices.count - 1) / Double(count - 1)
        var result: [Int] = []
        result.reserveCapacity(count)
        for outputIndex in 0..<count {
            if outputIndex.isMultiple(of: 256) { try cancellationCheck() }
            result.append(indices[Int((Double(outputIndex) * scale).rounded())])
        }
        return result
    }
}
