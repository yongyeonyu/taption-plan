import Foundation
import CryptoKit
import TaptionPlanEngine

extension RouteTimelineDataEngine {
    struct ResolvedCoordinate {
        let point: GeoPoint
        let isInterpolated: Bool
    }

    struct CoordinateIndex {
        private let values: [
            (timestamp: Date, point: GeoPoint, endsSegment: Bool)
        ]
        private let filtersSparseConnections: Bool

        init(
            readings: [SensorReading],
            includesApproximateLocations: Bool = false,
            filtersSparseConnections: Bool = false
        ) {
            self.filtersSparseConnections = filtersSparseConnections
            values = readings.compactMap { reading in
                guard let point = validPoint(
                    from: reading,
                    includesApproximateLocations: includesApproximateLocations
                ) else { return nil }
                return (
                    reading.timestamp,
                    point,
                    reading.trackingSessionEnded == true
                )
            }
        }

        func playbackCoordinate(
            at date: Date,
            sleepAnchors: [MapHomeSleepLocationAnchor] = []
        ) -> ResolvedCoordinate? {
            resolvedCoordinate(
                at: date,
                maximumGap: maximumInterpolationGap,
                sleepAnchors: sleepAnchors
            )
        }

        func routeCoordinate(
            at date: Date,
            sleepAnchors: [MapHomeSleepLocationAnchor] = []
        ) -> ResolvedCoordinate? {
            resolvedCoordinate(
                at: date,
                maximumGap: maximumInterpolationGap,
                sleepAnchors: sleepAnchors
            )
        }

        func isContinuous(from start: Date, to end: Date) -> Bool {
            guard values.count > 1, start < end else { return true }
            var index = max(1, upperBound(for: start))
            while index < values.count {
                let before = values[index - 1]
                let after = values[index]
                guard before.timestamp < end else { break }
                if after.timestamp > start {
                    let gap = after.timestamp.timeIntervalSince(before.timestamp)
                    if before.endsSegment
                        || gap > maximumInterpolationGap
                        || (filtersSparseConnections
                            && RouteSparseConnectionPolicy.breaksConnection(
                                gapDuration: gap,
                                distanceMeters: gap
                                        > RouteSparseConnectionPolicy.minimumSparseGapDuration
                                    ? distanceMeters(before.point, after.point)
                                    : nil
                            )) {
                        return false
                    }
                }
                if after.timestamp >= end { break }
                index += 1
            }
            return true
        }

        private func resolvedCoordinate(
            at date: Date,
            maximumGap: TimeInterval?,
            sleepAnchors: [MapHomeSleepLocationAnchor]
        ) -> ResolvedCoordinate? {
            guard let first = values.first else { return nil }
            if let sleepAnchor = MapHomeSleepLocationPolicy.contains(
                date,
                in: sleepAnchors
            ) {
                return ResolvedCoordinate(
                    point: sleepAnchor.point,
                    isInterpolated: false
                )
            }
            if date < first.timestamp {
                return ResolvedCoordinate(point: first.point, isInterpolated: false)
            }

            let insertionIndex = upperBound(for: date)
            let before = values[insertionIndex - 1]
            guard before.timestamp < date else {
                return ResolvedCoordinate(point: before.point, isInterpolated: false)
            }
            guard insertionIndex < values.count else {
                return ResolvedCoordinate(point: before.point, isInterpolated: false)
            }

            let after = values[insertionIndex]
            let gap = after.timestamp.timeIntervalSince(before.timestamp)
            guard !before.endsSegment,
                  gap > 0,
                  maximumGap.map({ gap <= $0 }) ?? true else {
                return ResolvedCoordinate(point: before.point, isInterpolated: false)
            }
            return ResolvedCoordinate(
                point: interpolate(
                    before.point,
                    after.point,
                    ratio: date.timeIntervalSince(before.timestamp) / gap
                ),
                isInterpolated: true
            )
        }

        private func upperBound(for date: Date) -> Int {
            var lower = 0
            var upper = values.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if values[middle].timestamp <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }
    }

    private struct SegmentAccumulator {
        let start: Date
        var end: Date
        let category: RouteTimelineCategory
        let opacity: Double
        var speedMetersPerSecond: Double?
        let confirmedSubwayTravelID: UUID?
        var coordinates: [GeoPoint]
        var coordinateTimestamps: [Date]

        var segment: RouteTimelineSegment {
            RouteTimelineSegment(
                id: segmentID(start: start, end: end, category: category),
                start: start,
                end: end,
                category: category,
                colorHex: category.colorHex,
                opacity: opacity,
                coordinates: coordinates,
                speedMetersPerSecond: speedMetersPerSecond,
                confirmedSubwayTravelID: confirmedSubwayTravelID,
                coordinateTimestamps: coordinateTimestamps
            )
        }
    }

    static func interpolate(
        _ lhs: GeoPoint,
        _ rhs: GeoPoint,
        ratio: Double
    ) -> GeoPoint {
        let t = min(1, max(0, ratio))
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return GeoPoint(
            latitude: blend(lhs.latitude, rhs.latitude),
            longitude: RouteTimelineLongitude.interpolate(
                from: lhs.longitude,
                to: rhs.longitude,
                fraction: t
            ),
            altitude: blendFinite(lhs.altitude, rhs.altitude, ratio: t, fallback: 0),
            horizontalAccuracy: mergedAccuracy(
                lhs.horizontalAccuracy,
                rhs.horizontalAccuracy
            ),
            verticalAccuracy: mergedAccuracy(
                lhs.verticalAccuracy,
                rhs.verticalAccuracy
            )
        )
    }

    private static func blendFinite(
        _ lhs: Double,
        _ rhs: Double,
        ratio: Double,
        fallback: Double
    ) -> Double {
        if lhs.isFinite, rhs.isFinite {
            return lhs + (rhs - lhs) * ratio
        }
        if lhs.isFinite { return lhs }
        if rhs.isFinite { return rhs }
        return fallback
    }

    private static func mergedAccuracy(_ lhs: Double, _ rhs: Double) -> Double {
        let values = [lhs, rhs].filter { $0.isFinite && $0 >= 0 }
        return values.max() ?? -1
    }

    static func confirmedSubwayCoordinates(
        for segment: TravelSegment,
        through cutoff: Date
    ) -> [GeoPoint] {
        guard RouteConfirmedSubwayIntervalIndex.isConfirmedSubway(segment),
              let coordinates = segment.subwayRoute.map(SubwayRideTrack.coordinates(of:)),
              let first = coordinates.first,
              cutoff >= segment.span.start else { return [] }
        guard cutoff < segment.span.end, segment.span.duration > 0 else {
            return coordinates
        }
        let progress = min(
            1,
            max(
                0,
                cutoff.timeIntervalSince(segment.span.start)
                    / segment.span.duration
            )
        )
        guard progress > 0 else { return [first] }
        let lengths = zip(coordinates, coordinates.dropFirst()).map {
            distanceMeters($0.0, $0.1)
        }
        let target = lengths.reduce(0, +) * progress
        var traversed = 0.0
        var result = [first]
        for (index, length) in lengths.enumerated() {
            let next = coordinates[index + 1]
            guard traversed + length < target, length > 0 else {
                let ratio = length > 0
                    ? min(1, max(0, (target - traversed) / length))
                    : 1
                result.append(interpolate(coordinates[index], next, ratio: ratio))
                return result
            }
            result.append(next)
            traversed += length
        }
        return coordinates
    }

    static func confirmedSubwayCoordinate(
        at date: Date,
        index: RouteConfirmedSubwayIntervalIndex
    ) -> GeoPoint? {
        guard let segment = index.segment(at: date) else {
            return nil
        }
        return confirmedSubwayCoordinates(for: segment, through: date).last
    }

    static func makeSegments(
        samples: [RouteTimelineSample],
        coordinateIndex: CoordinateIndex,
        actuals: [ActualRecord],
        categoryIndex: CategoryIndex,
        confirmedSubwayIndex: RouteConfirmedSubwayIntervalIndex,
        cutoff: Date,
        selectedCategory: RouteTimelineCategory?,
        selectedSpan: TimeSpan?,
        sleepSpans: [TimeSpan],
        sleepAnchors: [MapHomeSleepLocationAnchor]
    ) -> [RouteTimelineSegment] {
        guard let first = samples.first, first.timestamp < cutoff else { return [] }
        let interiorBoundaries = (
            samples.map(\.timestamp)
                + actuals.flatMap { actual in
                    [actual.startedAt, actual.endedAt ?? cutoff]
                }
                + sleepSpans.flatMap { [$0.start, $0.end] }
                + confirmedSubwayIndex.segments.flatMap {
                    [$0.span.start, $0.span.end]
                }
        ).filter { $0 > first.timestamp && $0 < cutoff }
        let boundaries = Set(
            [first.timestamp, cutoff] + interiorBoundaries
        ).sorted()
        var result: [RouteTimelineSegment] = []
        var accumulator: SegmentAccumulator?
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let sleepAnchor = MapHomeSleepLocationPolicy.contains(
                midpoint,
                in: sleepAnchors
            )?.point
            guard coordinateIndex.isContinuous(from: start, to: end),
                  let resolvedStart = coordinateIndex.routeCoordinate(
                      at: start,
                      sleepAnchors: sleepAnchors
                  )?.point,
                  let resolvedEnd = coordinateIndex.routeCoordinate(
                      at: end,
                      sleepAnchors: sleepAnchors
                  )?.point else { continue }
            let startPoint = sleepAnchor ?? resolvedStart
            let endPoint = sleepAnchor ?? resolvedEnd
            guard
                  !sameLocation(startPoint, endPoint) else { continue }
            let category = categoryIndex.category(at: midpoint)
            let confirmedSubwayTravelID = confirmedSubwayIndex
                .segment(at: midpoint)?.id
            let speedMetersPerSecond = measuredSpeed(
                from: startPoint,
                to: endPoint,
                over: end.timeIntervalSince(start)
            )
            let opacity: Double
            if let selectedSpan {
                opacity = selectedSpan.contains(midpoint) ? 1.0 : 0.5
            } else {
                opacity = selectedCategory == nil || category == selectedCategory ? 1.0 : 0.5
            }
            if var current = accumulator,
               current.category == category,
               current.opacity == opacity,
               current.confirmedSubwayTravelID == confirmedSubwayTravelID,
               speedsCanMerge(
                   current.speedMetersPerSecond,
                   speedMetersPerSecond,
                   interval: end.timeIntervalSince(start),
                   sampleCount: samples.count
               ),
               current.end == start {
                current.end = end
                if !sameLocation(current.coordinates.last, endPoint) {
                    current.coordinates.append(endPoint)
                    current.coordinateTimestamps.append(end)
                }
                current.speedMetersPerSecond = measuredSpeed(
                    from: current.coordinates[0],
                    to: endPoint,
                    over: current.end.timeIntervalSince(current.start)
                )
                accumulator = current
            } else {
                if let accumulator {
                    result.append(accumulator.segment)
                }
                accumulator = SegmentAccumulator(
                    start: start,
                    end: end,
                    category: category,
                    opacity: opacity,
                    speedMetersPerSecond: speedMetersPerSecond,
                    confirmedSubwayTravelID: confirmedSubwayTravelID,
                    coordinates: sameLocation(startPoint, endPoint)
                        ? [startPoint]
                        : [startPoint, endPoint],
                    coordinateTimestamps: sameLocation(startPoint, endPoint)
                        ? [start]
                        : [start, end]
                )
            }
        }
        if let accumulator {
            result.append(accumulator.segment)
        }
        return result
    }

    private static func segmentID(
        start: Date,
        end: Date,
        category: RouteTimelineCategory
    ) -> String {
        "\(category.rawValue)-\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)"
    }

    private static func measuredSpeed(
        from start: GeoPoint,
        to end: GeoPoint,
        over duration: TimeInterval
    ) -> Double? {
        guard duration > 0, duration.isFinite else { return nil }
        let distance = distanceMeters(start, end)
        guard distance.isFinite, distance > 0 else { return nil }
        let speed = distance / duration
        return speed.isFinite && speed >= 0 ? speed : nil
    }

    private static func speedsCanMerge(
        _ lhs: Double?,
        _ rhs: Double?,
        interval: TimeInterval,
        sampleCount: Int
    ) -> Bool {
        // A dense archive is one continuous logger cluster. The map can
        // still use the aggregate speed for its gradient without fragmenting
        // that cluster into dozens of tiny polylines.
        guard sampleCount <= 3 else { return true }
        // Sub-minute samples are logger cadence, not a meaningful speed
        // change. Keep those points in one polyline and only split the
        // display segment when a longer observation supports a gradient.
        guard interval >= 60 else { return true }
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            let tolerance = max(0.25, max(abs(left), abs(right)) * 0.1)
            return abs(left - right) <= tolerance
        default:
            return false
        }
    }

    static func preferredReading(
        _ lhs: SensorReading,
        _ rhs: SensorReading
    ) -> Bool {
        let leftIsApproximate = lhs.locationFixQuality == .approximate
            || !lhs.gpsAvailable
        let rightIsApproximate = rhs.locationFixQuality == .approximate
            || !rhs.gpsAvailable
        if leftIsApproximate != rightIsApproximate {
            return !leftIsApproximate
        }
        let leftAccuracy = accuracyRank(lhs.point?.horizontalAccuracy)
        let rightAccuracy = accuracyRank(rhs.point?.horizontalAccuracy)
        if leftAccuracy != rightAccuracy { return leftAccuracy < rightAccuracy }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? .max) < (rhs.sequence ?? .max) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func accuracyRank(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else {
            return .greatestFiniteMagnitude
        }
        return value
    }

    static func validPoint(
        from reading: SensorReading,
        includesApproximateLocations: Bool = false
    ) -> GeoPoint? {
        guard let point = reading.point,
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude) else { return nil }
        let isPrecise = reading.gpsAvailable
            && reading.locationFixQuality != .approximate
        let isUsableApproximate = includesApproximateLocations
            && !isPrecise
            && (reading.locationFixQuality == .approximate
                || reading.locationFixQuality == nil)
            && point.horizontalAccuracy.isFinite
            && point.horizontalAccuracy >= 0
            && point.horizontalAccuracy <= maximumApproximateDisplayAccuracy
        guard isPrecise || isUsableApproximate else { return nil }
        return GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
            altitude: point.altitude.isFinite ? point.altitude : 0,
            horizontalAccuracy: point.horizontalAccuracy.isFinite
                && point.horizontalAccuracy >= 0
                ? point.horizontalAccuracy
                : -1,
            verticalAccuracy: point.verticalAccuracy.isFinite
                && point.verticalAccuracy >= 0
                ? point.verticalAccuracy
                : -1
        )
    }

    private static func sameLocation(_ lhs: GeoPoint?, _ rhs: GeoPoint?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.latitude == rhs.latitude
            && RouteTimelineLongitude.shortestDelta(
                from: lhs.longitude,
                to: rhs.longitude
            ) == 0
    }
}
