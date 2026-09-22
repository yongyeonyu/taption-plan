import Foundation
import TaptionPlanEngine

struct TaptionRouteDisplaySnapshot: Sendable {
    let log: RouteLog
    let selectedCoordinate: RouteCoordinate?
    let movingRanges: [TaptionRouteMinuteRange]
}

struct TaptionRouteMinuteRange: Hashable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }
}

struct TaptionRoutePlaybackInput: Sendable {
    let currentSpeedMetersPerSecond: Double
    let movementDetected: Bool

    var rateMetersPerSecond: Double {
        RoutePlaybackPolicy.rate(
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            movementDetected: movementDetected
        )
    }
}

enum TaptionRouteEngineAdapter {
    static func displaySnapshot(
        readings: [SensorReading],
        selectedDate: Date? = nil
    ) -> TaptionRouteDisplaySnapshot {
        let log = displayRoute(from: readings)
        let index = RouteTimeCoordinateIndex(
            segments: log.segments.map(\.pathSamples)
        )
        return TaptionRouteDisplaySnapshot(
            log: log,
            selectedCoordinate: selectedDate.flatMap(index.sample(at:))?.coordinate,
            movingRanges: movingMinuteRanges(from: readings)
        )
    }

    static func displayRoute(from readings: [SensorReading]) -> RouteLog {
        RouteLoggerRouteFilter().filter(samples(from: readings))
    }

    static func displayRoute(
        from readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> RouteLog {
        try RouteLoggerRouteFilter().filter(
            samples(from: readings, cancellationCheck: cancellationCheck),
            cancellationCheck: cancellationCheck
        )
    }

    static func filteredReadings(
        from readings: [SensorReading],
        includeLowConfidenceBoundaries: Bool = true
    ) -> [SensorReading] {
        filteredReadings(
            from: readings,
            includeLowConfidenceBoundaries: includeLowConfidenceBoundaries,
            cancellationCheck: {}
        )
    }

    static func filteredReadings(
        from readings: [SensorReading],
        includeLowConfidenceBoundaries: Bool = true,
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        var originals: [UUID: SensorReading] = [:]
        originals.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if let current = originals[reading.id] {
                if preferredOriginalReading(reading, current) {
                    originals[reading.id] = reading
                }
            } else {
                originals[reading.id] = reading
            }
        }
        let segments = try displayRoute(
            from: readings,
            cancellationCheck: cancellationCheck
        ).segments
        var result: [SensorReading] = []
        result.reserveCapacity(readings.count)
        for index in segments.indices {
            if index.isMultiple(of: 64) { try cancellationCheck() }
            let segment = segments[index]
            var samples = segment.pathSamples
            if includeLowConfidenceBoundaries {
                samples.append(contentsOf: segment.boundarySamples)
            }
            try cancellationCheck()
            samples = try RouteTimelineCancellableSort.sorted(
                samples,
                by: { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp {
                        return lhs.timestamp < rhs.timestamp
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                },
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
            var derived: [SensorReading] = []
            derived.reserveCapacity(samples.count)
            for (sampleIndex, sample) in samples.enumerated() {
                if sampleIndex.isMultiple(of: 256) { try cancellationCheck() }
                guard var reading = originals[sample.id] else { continue }
                reading.point = GeoPoint(
                    latitude: sample.coordinate.latitude,
                    longitude: sample.coordinate.longitude,
                    altitude: reading.point?.altitude ?? 0,
                    horizontalAccuracy: sample.horizontalAccuracyMeters,
                    verticalAccuracy: reading.point?.verticalAccuracy ?? -1
                )
                derived.append(reading)
            }
            if index < segments.index(before: segments.endIndex),
               !derived.isEmpty {
                derived[derived.count - 1].trackingSessionEnded = true
            }
            result.append(contentsOf: derived)
        }
        try cancellationCheck()
        var seen = Set<UUID>()
        var unique: [SensorReading] = []
        unique.reserveCapacity(result.count)
        for (index, reading) in result.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if seen.insert(reading.id).inserted { unique.append(reading) }
        }
        try cancellationCheck()
        unique = try sortedReadings(
            unique,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return unique
    }

    static func sortedReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try RouteTimelineCancellableSort.sorted(
            readings,
            by: { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.id.uuidString < rhs.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }

    static func samples(from readings: [SensorReading]) -> [RouteSample] {
        samples(from: readings, cancellationCheck: {})
    }

    static func samples(
        from readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [RouteSample] {
        try cancellationCheck()
        var result: [RouteSample] = []
        result.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let point = reading.point else { continue }
            let mode = routeMode(for: reading)
            result.append(RouteSample(
                id: reading.id,
                timestamp: reading.timestamp,
                coordinate: RouteCoordinate(latitude: point.latitude, longitude: point.longitude),
                horizontalAccuracyMeters: point.horizontalAccuracy,
                speedMetersPerSecond: reading.speedMetersPerSecond,
                speedAccuracyMetersPerSecond: reading.speedAccuracyMetersPerSecond,
                sequence: reading.sequence.map(Int64.init),
                mode: mode,
                isApproximate: reading.locationFixQuality == .approximate
                    || !reading.gpsAvailable
            ))
        }
        try cancellationCheck()
        return result
    }

    static func coordinate(
        at date: Date,
        readings: [SensorReading]
    ) -> RouteCoordinate? {
        let log = displayRoute(from: readings)
        return RouteTimeCoordinateIndex(
            segments: log.segments.map(\.pathSamples)
        )
            .sample(at: date)?.coordinate
    }

    static func movingMinuteRanges(from readings: [SensorReading]) -> [TaptionRouteMinuteRange] {
        let ordered = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.point != nil
                    && $0.motion.isMovement
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }
        var result: [TaptionRouteMinuteRange] = []
        var start = first.timestamp
        var previous = first.timestamp
        for reading in ordered.dropFirst() {
            if reading.timestamp.timeIntervalSince(previous) > 15 * 60 {
                result.append(.init(start: start, end: previous))
                start = reading.timestamp
            }
            previous = reading.timestamp
        }
        result.append(.init(start: start, end: previous))
        return result
    }

    static func playbackInput(
        at date: Date,
        readings: [SensorReading]
    ) -> TaptionRoutePlaybackInput {
        let reading = RouteTimelineTimestamp.isValid(date)
            ? readings.filter { RouteTimelineTimestamp.isValid($0.timestamp) }.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
            }
            : nil
        return TaptionRoutePlaybackInput(
            currentSpeedMetersPerSecond: max(0, reading?.speedMetersPerSecond ?? 0),
            movementDetected: reading?.motion.isMovement == true
        )
    }

    static func allowsDottedRoute(
        for segment: TravelSegment,
        readings: [SensorReading]
    ) -> Bool {
        guard !segment.isConfirmed,
              !hasCompleteRecordedRoute(for: segment, readings: readings) else {
            return false
        }
        let segmentReadings = readings.filter {
            $0.timestamp >= segment.span.start && $0.timestamp <= segment.span.end
        }
        let subwayEvidence = subwayEvidence(from: segmentReadings, segment: segment)
        let distance = segment.distanceMeters > 0
            ? segment.distanceMeters
            : distance(of: segmentReadings)
        let observedDistance = Self.distance(of: segmentReadings)
        let hasMotion = segmentReadings.contains { $0.motion.isMovement }
            || observedDistance > 20
        let hasContinuity = !segment.evidence.isEmpty
        return RouteEvidenceGate.allowsDottedRoute(
            MissingRouteEvidence(
                motionDetected: hasMotion,
                cellularContinuity: hasContinuity,
                subwayWiFi: segmentReadings.contains {
                    SubwayWiFiSSID.hasContinuousEvidence(
                        streak: $0.subwayWiFiObservationStreak
                    )
                },
                subway: subwayEvidence,
                observedDistanceMeters: distance
            )
        )
    }

    static func hasCompleteRecordedRoute(
        for segment: TravelSegment,
        readings: [SensorReading]
    ) -> Bool {
        hasCompleteRecordedRoute(in: segment.span, readings: readings)
    }

    static func hasCompleteRecordedRoute(
        in span: TimeSpan,
        readings: [SensorReading]
    ) -> Bool {
        guard RouteTimelineTimestamp.isValid(span.start),
              RouteTimelineTimestamp.isValid(span.end) else { return false }
        let maximumGap = RouteSparseConnectionPolicy.maximumGapDuration
        let route = readings
            .filter { reading in
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      reading.timestamp >= span.start,
                      reading.timestamp <= span.end,
                      reading.gpsAvailable,
                      reading.locationFixQuality != .approximate,
                      let point = reading.point else {
                    return false
                }
                return point.latitude.isFinite
                    && point.longitude.isFinite
                    && (-90...90).contains(point.latitude)
                    && (-180...180).contains(point.longitude)
                    && point.horizontalAccuracy.isFinite
                    && point.horizontalAccuracy >= 0
                    && point.horizontalAccuracy <= 150
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = route.first,
              let last = route.last,
              route.count >= 2,
              distance(of: route) > 20,
              first.timestamp.timeIntervalSince(span.start) <= maximumGap,
              span.end.timeIntervalSince(last.timestamp) <= maximumGap else {
            return false
        }
        return zip(route, route.dropFirst()).allSatisfy {
            let duration = $1.timestamp.timeIntervalSince($0.timestamp)
            guard duration <= maximumGap else { return false }
            let distanceMeters: Double?
            if duration > RouteSparseConnectionPolicy.minimumSparseGapDuration,
               let lhs = $0.point,
               let rhs = $1.point {
                distanceMeters = coordinateDistance(
                    RouteCoordinate(latitude: lhs.latitude, longitude: lhs.longitude),
                    RouteCoordinate(latitude: rhs.latitude, longitude: rhs.longitude)
                )
            } else {
                distanceMeters = nil
            }
            return !RouteSparseConnectionPolicy.breaksConnection(
                gapDuration: duration,
                distanceMeters: distanceMeters
            )
        }
    }

    private static func routeMode(for reading: SensorReading) -> RouteTravelMode {
        if reading.matchesRailRoute
            || SubwayWiFiSSID.hasContinuousEvidence(
                streak: reading.subwayWiFiObservationStreak
            ) {
            return .subway
        }
        switch reading.motion {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .automotive
        case .stationary, .unknown: return .unknown
        }
    }

    private static func preferredOriginalReading(
        _ lhs: SensorReading,
        _ rhs: SensorReading
    ) -> Bool {
        let payloadRank: (SensorReading) -> Int = { reading in
            guard let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= 150 else {
                return 0
            }
            return reading.gpsAvailable
                && reading.locationFixQuality != .approximate ? 2 : 1
        }
        let lhsPayloadRank = payloadRank(lhs)
        let rhsPayloadRank = payloadRank(rhs)
        if lhsPayloadRank != rhsPayloadRank {
            return lhsPayloadRank > rhsPayloadRank
        }
        let lhsAccuracy: Double = {
            guard let value = lhs.point?.horizontalAccuracy,
                  value.isFinite,
                  value >= 0 else {
                return .greatestFiniteMagnitude
            }
            return value
        }()
        let rhsAccuracy: Double = {
            guard let value = rhs.point?.horizontalAccuracy,
                  value.isFinite,
                  value >= 0 else {
                return .greatestFiniteMagnitude
            }
            return value
        }()
        if lhsAccuracy != rhsAccuracy {
            return lhsAccuracy < rhsAccuracy
        }
        if lhs.sequence != rhs.sequence {
            return (lhs.sequence ?? .min) > (rhs.sequence ?? .min)
        }
        return lhs.timestamp < rhs.timestamp
    }

    private static func subwayEvidence(
        from readings: [SensorReading],
        segment: TravelSegment
    ) -> SubwayRouteEvidence? {
        let names = readings.compactMap(\.nearbyStationName)
            .reduce(into: [String]()) { result, name in
                if result.last != name { result.append(name) }
            }
        let coordinates = readings.compactMap(\.point).map {
            RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let routeCoordinates = segment.subwayRoute?.coordinates.compactMap {
            RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        } ?? coordinates
        guard names.count >= 2, routeCoordinates.count >= 2 else { return nil }
        return SubwayRouteEvidence(
            lineName: segment.subwayRoute?.lineNames.first ?? "subway",
            stationNames: names,
            coordinates: routeCoordinates,
            confidence: segment.mode == .subway ? 1 : 0.6
        )
    }

    private static func distance(of readings: [SensorReading]) -> Double {
        let samples = samples(from: readings)
        return zip(samples, samples.dropFirst()).reduce(0) {
            $0 + coordinateDistance($1.0.coordinate, $1.1.coordinate)
        }
    }

    private static func coordinateDistance(_ lhs: RouteCoordinate, _ rhs: RouteCoordinate) -> Double {
        let latitude = (lhs.latitude + rhs.latitude) * .pi / 360
        let north = (rhs.latitude - lhs.latitude) * 111_320
        let east = RouteTimelineLongitude.shortestDelta(
            from: lhs.longitude,
            to: rhs.longitude
        ) * 111_320 * cos(latitude)
        return hypot(north, east)
    }
}
