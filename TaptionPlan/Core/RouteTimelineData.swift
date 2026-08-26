import Foundation

/// The eight categories used by the map and the automatic timeline.  This
/// palette is a data contract; UI layers can turn the hex value into a Color.
enum RouteTimelineCategory: String, CaseIterable, Hashable, Sendable {
    case activity
    case work
    case study
    case hobby
    case sleep
    case movement
    case exercise
    case unconfirmed

    static let ordered: [Self] = [
        .activity, .work, .study, .hobby,
        .sleep, .movement, .exercise, .unconfirmed,
    ]

    var colorHex: String {
        switch self {
        case .activity: "#29A383"
        case .work: "#2563EB"
        case .study: "#00A2C7"
        case .hobby: "#8B5CF6"
        case .sleep: "#5B5BD6"
        case .movement: "#F76B15"
        case .exercise: "#DC2626"
        case .unconfirmed: "#94A3B8"
        }
    }

    static func resolve(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .activity
    }
}

struct RouteTimelineSample: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let point: GeoPoint
    let category: RouteTimelineCategory
}

struct RouteTimelineSegment: Identifiable, Hashable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let category: RouteTimelineCategory
    let colorHex: String
    let opacity: Double
    let coordinates: [GeoPoint]
    /// Display-only speed derived from the observed endpoints and timestamps.
    /// It is nil when an interval has no measurable movement.
    let speedMetersPerSecond: Double?
    let confirmedSubwayTravelID: UUID?
}

/// Maps observed movement speeds to a stable cool-to-warm route palette.
/// The range is calculated from the visible route, so a walking route and a
/// driving route each use the full gradient without changing stored readings.
enum RouteSpeedGradient {
    private static let stops: [(position: Double, red: Double, green: Double, blue: Double)] = [
        (0.0, 37 / 255, 99 / 255, 235 / 255),       // blue
        (0.5, 20 / 255, 184 / 255, 166 / 255),      // teal
        (0.78, 249 / 255, 115 / 255, 22 / 255),     // orange
        (1.0, 220 / 255, 38 / 255, 38 / 255),       // red
    ]

    static func normalized(
        speedMetersPerSecond speed: Double?,
        in speeds: [Double]
    ) -> Double? {
        guard let speed, speed.isFinite, speed >= 0 else { return nil }
        let finite = speeds.filter { $0.isFinite && $0 >= 0 }
        guard let minimum = finite.min(),
              let maximum = finite.max() else { return nil }
        let range = maximum - minimum
        guard range > 0.001 else { return 0.5 }
        return min(1, max(0, (speed - minimum) / range))
    }

    static func colorHex(
        speedMetersPerSecond speed: Double?,
        in speeds: [Double]
    ) -> String? {
        guard let normalized = normalized(
            speedMetersPerSecond: speed,
            in: speeds
        ) else { return nil }
        let lowerIndex = stops.lastIndex { $0.position <= normalized } ?? 0
        let upperIndex = min(stops.count - 1, lowerIndex + 1)
        let lower = stops[lowerIndex]
        let upper = stops[upperIndex]
        let interval = upper.position - lower.position
        let ratio = interval > 0
            ? (normalized - lower.position) / interval
            : 0
        func blend(_ lhs: Double, _ rhs: Double) -> Int {
            let value = lhs + (rhs - lhs) * ratio
            return Int((value * 255.0).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            blend(lower.red, upper.red),
            blend(lower.green, upper.green),
            blend(lower.blue, upper.blue)
        )
    }
}

struct RouteTimelineProjection: Hashable, Sendable {
    let selectedDate: Date
    let cutoff: Date
    let selectedCategory: RouteTimelineCategory?
    let samples: [RouteTimelineSample]
    let segments: [RouteTimelineSegment]
    let coordinateAtCutoff: GeoPoint?
}

/// Projects an immutable route snapshot into the current visible window.
/// This is intentionally display-only: archived readings and segments remain
/// untouched while a viewport is panned or zoomed.
enum RouteTimelineRenderProjection {
    static func segments(
        _ source: [RouteTimelineSegment],
        in span: TimeSpan
    ) -> [RouteTimelineSegment] {
        source.compactMap { segment in
            guard let overlap = segmentSpan(segment).intersection(with: span),
                  overlap.duration > 0 else { return nil }
            guard overlap.start != segment.start || overlap.end != segment.end else {
                return segment
            }
            return RouteTimelineSegment(
                id: segment.id,
                start: overlap.start,
                end: overlap.end,
                category: segment.category,
                colorHex: segment.colorHex,
                opacity: segment.opacity,
                coordinates: segment.coordinates,
                speedMetersPerSecond: segment.speedMetersPerSecond,
                confirmedSubwayTravelID: segment.confirmedSubwayTravelID
            )
        }
    }

    private static func segmentSpan(_ segment: RouteTimelineSegment) -> TimeSpan {
        TimeSpan(start: segment.start, end: segment.end)
    }
}

enum ExpectedRouteTransport: String, Hashable, Sendable {
    case automobile
    case transit
    case walking
}

struct ExpectedRouteRequest: Identifiable, Hashable, Sendable {
    let segmentID: UUID
    let mode: TravelMode
    let transport: ExpectedRouteTransport
    let start: GeoPoint
    let end: GeoPoint
    let departureDate: Date
    let arrivalDate: Date

    var id: UUID { segmentID }
}

/// Produces display-only network-route requests. The returned requests never
/// replace archived GPS points or mutate classified travel segments.
enum ExpectedRouteRequestEngine {
    static let minimumRouteDistanceMeters: Double = 20

    static func requests(
        travel: [TravelSegment],
        places: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date
    ) -> [ExpectedRouteRequest] {
        let placesByID = places.reduce(into: [UUID: PlaceStay]()) {
            $0[$1.id] = $1
        }
        let orderedReadings = readings
            .filter { reading in
                guard let point = reading.point else { return false }
                return isValid(point)
                    && reading.timestamp >= day.start
                    && reading.timestamp <= day.end
            }
            .sorted { $0.timestamp < $1.timestamp }

        return travel
            .sorted { $0.span.start < $1.span.start }
            .compactMap { segment in
                guard segment.span.intersection(with: day) != nil,
                      segment.span.start < cutoff,
                      let transport = transport(for: segment),
                      !usesStoredSubwayPath(segment),
                      TaptionRouteEngineAdapter.allowsDottedRoute(
                          for: segment,
                          readings: orderedReadings
                      ) else { return nil }

                let visibleEnd = min(segment.span.end, cutoff)
                guard segment.span.start < visibleEnd else { return nil }
                let visibleSpan = TimeSpan(
                    start: max(segment.span.start, day.start),
                    end: min(visibleEnd, day.end)
                )
                let readingsInSegment = orderedReadings.filter {
                    $0.timestamp >= visibleSpan.start
                        && $0.timestamp <= visibleSpan.end
                }

                let start = readingsInSegment
                    .first(where: reliableLocationReading)?
                    .point
                    ?? confirmedPlacePoint(
                        id: segment.fromPlaceID,
                        segment: segment,
                        placesByID: placesByID
                    )
                let end: GeoPoint?
                if visibleEnd < segment.span.end {
                    end = readingsInSegment
                        .last(where: reliableLocationReading)?
                        .point
                } else {
                    end = readingsInSegment
                        .last(where: reliableLocationReading)?
                        .point
                        ?? confirmedPlacePoint(
                            id: segment.toPlaceID,
                            segment: segment,
                            placesByID: placesByID
                        )
                }

                guard let start, let end,
                      distanceMeters(start, end) >= minimumRouteDistanceMeters
                else { return nil }
                return ExpectedRouteRequest(
                    segmentID: segment.id,
                    mode: segment.mode,
                    transport: transport,
                    start: start,
                    end: end,
                    departureDate: visibleSpan.start,
                    arrivalDate: visibleSpan.end
                )
            }
    }

    private static func usesStoredSubwayPath(_ segment: TravelSegment) -> Bool {
        segment.mode == .subway
            && segment.isConfirmed
            && (segment.subwayRoute?.coordinates.count ?? 0) >= 2
    }

    private static func transport(
        for segment: TravelSegment
    ) -> ExpectedRouteTransport? {
        switch segment.mode {
        case .car, .taxi, .bus:
            .automobile
        case .subway, .train:
            .transit
        case .walking, .running, .cycling:
            .walking
        case .airplane, .ship:
            nil
        }
    }

    private static func reliableLocationReading(
        _ reading: SensorReading
    ) -> Bool {
        guard let point = reading.point else { return false }
        return isValid(point)
            && reading.locationFixQuality != .approximate
            && (point.horizontalAccuracy < 0
                || point.horizontalAccuracy <= 150)
    }

    private static func confirmedPlacePoint(
        id: UUID?,
        segment: TravelSegment,
        placesByID: [UUID: PlaceStay]
    ) -> GeoPoint? {
        guard segment.isConfirmed,
              let id,
              let point = placesByID[id]?.point,
              isValid(point) else { return nil }
        return point
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}

/// Reduces raw location observations to a deterministic, display-only track.
/// The source readings remain untouched and are still the archive of record.
enum GPSLoggerRouteFilter {
    struct Configuration: Hashable, Sendable {
        var maximumPreciseAccuracy: Double = 150
        var maximumDisplayAccuracy: Double = 1_000
        var minimumMovementDistance: Double = 2
        var stationarySpeed: Double = 0.75
        var maximumPlausibleSpeed: Double = 55
        var absoluteMaximumSpeed: Double = 120
        var maximumGap: TimeInterval = 15 * 60
        var sparseGap: TimeInterval = 5 * 60
        var sparseDistance: Double = 1_000
        var innovationSigma: Double = 3
        var processAcceleration: Double = 4

        static let `default` = Configuration()
    }

    private struct MeterPoint: Hashable {
        var east: Double
        var north: Double

        static let zero = MeterPoint(east: 0, north: 0)
    }

    private struct Candidate {
        let reading: SensorReading
        let point: GeoPoint
        let accuracy: Double
        let isPrecise: Bool
    }

    private struct KalmanState {
        var originLatitude: Double
        var originLongitude: Double
        var position: MeterPoint
        var velocity: MeterPoint
        var positionVariance: Double
        var velocityVariance: Double

        init(candidate: Candidate) {
            originLatitude = candidate.point.latitude
            originLongitude = candidate.point.longitude
            position = MeterPoint.zero
            velocity = MeterPoint.zero
            positionVariance = max(25, candidate.accuracy * candidate.accuracy)
            velocityVariance = 25
        }

        mutating func update(
            candidate: Candidate,
            after elapsed: TimeInterval,
            sigmaLimit: Double,
            processAcceleration: Double
        ) -> (point: GeoPoint, uncertainty: Double)? {
            let dt = max(0, elapsed)
            let measurement = Self.project(
                candidate.point,
                originLatitude: originLatitude,
                originLongitude: originLongitude
            )
            let accelerationVariance = max(0.25, processAcceleration * processAcceleration)
            let predictedPosition = MeterPoint(
                east: position.east + velocity.east * dt,
                north: position.north + velocity.north * dt
            )
            let predictedVariance = max(
                1,
                positionVariance
                    + velocityVariance * dt * dt
                    + accelerationVariance * max(dt, 1) * max(dt, 1) / 4
            )
            let measurementVariance = max(25, candidate.accuracy * candidate.accuracy)
            let innovation = MeterPoint(
                east: measurement.east - predictedPosition.east,
                north: measurement.north - predictedPosition.north
            )
            let innovationDistance = hypot(innovation.east, innovation.north)
            let innovationSigma = sqrt(predictedVariance + measurementVariance)
            guard innovationDistance <= sigmaLimit * innovationSigma else {
                return nil
            }

            let gain = predictedVariance / (predictedVariance + measurementVariance)
            let correctedPosition = MeterPoint(
                east: predictedPosition.east + gain * innovation.east,
                north: predictedPosition.north + gain * innovation.north
            )
            let velocityGain = dt > 0 ? min(0.5, gain / max(dt, 1)) : 0
            let correctedVelocity = MeterPoint(
                east: velocity.east + velocityGain * innovation.east,
                north: velocity.north + velocityGain * innovation.north
            )
            position = correctedPosition
            velocity = correctedVelocity
            positionVariance = max(1, (1 - gain) * predictedVariance)
            velocityVariance = max(1, velocityVariance * (1 - min(0.5, gain)))

            let output = Self.unproject(
                correctedPosition,
                originLatitude: originLatitude,
                originLongitude: originLongitude,
                source: candidate.point,
                uncertainty: sqrt(positionVariance)
            )
            return (output, sqrt(positionVariance))
        }

        private static func project(
            _ point: GeoPoint,
            originLatitude: Double,
            originLongitude: Double
        ) -> MeterPoint {
            let latitudeScale = 111_132.92
            let longitudeScale = 111_412.84
                * cos(originLatitude * .pi / 180)
            return MeterPoint(
                east: (point.longitude - originLongitude) * longitudeScale,
                north: (point.latitude - originLatitude) * latitudeScale
            )
        }

        private static func unproject(
            _ point: MeterPoint,
            originLatitude: Double,
            originLongitude: Double,
            source: GeoPoint,
            uncertainty: Double
        ) -> GeoPoint {
            let latitudeScale = 111_132.92
            let longitudeScale = 111_412.84
                * cos(originLatitude * .pi / 180)
            return GeoPoint(
                latitude: originLatitude + point.north / latitudeScale,
                longitude: originLongitude + point.east / longitudeScale,
                altitude: source.altitude.isFinite ? source.altitude : 0,
                horizontalAccuracy: max(
                    source.horizontalAccuracy,
                    uncertainty.isFinite ? uncertainty : 0
                ),
                verticalAccuracy: source.verticalAccuracy.isFinite
                    && source.verticalAccuracy >= 0
                    ? source.verticalAccuracy
                    : -1
            )
        }
    }

    static func filter(
        _ readings: [SensorReading],
        configuration: Configuration = .default
    ) -> [SensorReading] {
        let candidates = normalizedCandidates(
            readings,
            configuration: configuration
        )
        guard !candidates.isEmpty else { return [] }

        let lowConfidenceBoundaries = boundaryCandidates(
            from: candidates
        ).map { derivedReading($0, point: $0.point) }
        let preciseCandidates = candidates.filter(\.isPrecise)
        guard let first = preciseCandidates.first else {
            return lowConfidenceBoundaries
                .sorted(by: deterministicReadingOrder)
        }

        var result: [SensorReading] = []
        result.reserveCapacity(preciseCandidates.count + lowConfidenceBoundaries.count)
        var lastCandidate = first
        var lastOutput = first.point
        var state = KalmanState(candidate: first)
        var startsNewSegment = false
        result.append(derivedReading(first, point: first.point))

        for candidate in preciseCandidates.dropFirst() {
            let elapsed = candidate.reading.timestamp.timeIntervalSince(
                lastCandidate.reading.timestamp
            )
            guard elapsed > 0 else { continue }

            if startsNewSegment || elapsed > configuration.maximumGap {
                closeLastSegment(&result)
                state = KalmanState(candidate: candidate)
                lastCandidate = candidate
                lastOutput = candidate.point
                result.append(derivedReading(candidate, point: candidate.point))
                startsNewSegment = false
                continue
            }

            let displacement = distanceMeters(lastOutput, candidate.point)
            let threshold = max(
                configuration.minimumMovementDistance,
                min(8, candidate.accuracy * 0.35)
            )
            let reportedSpeed = candidate.reading.speedMetersPerSecond
            let isStationary: Bool
            if candidate.reading.motion == .stationary {
                isStationary = true
            } else if let reportedSpeed {
                isStationary = reportedSpeed.isFinite
                    && reportedSpeed >= 0
                    && reportedSpeed <= configuration.stationarySpeed
            } else {
                isStationary = displacement <= threshold
            }
            if displacement <= threshold, isStationary {
                continue
            }

            let previousAccuracy = max(5, lastCandidate.accuracy)
            let accuracyAllowance = 3 * hypot(previousAccuracy, candidate.accuracy)
            let measuredSpeed: Double? = {
                guard let speed = candidate.reading.speedMetersPerSecond,
                      speed.isFinite, speed >= 0,
                      let speedAccuracy = candidate.reading
                        .speedAccuracyMetersPerSecond,
                      speedAccuracy.isFinite, speedAccuracy >= 0
                else { return nil }
                return speed + 3 * speedAccuracy
            }()
            let maximumSpeed = min(
                configuration.absoluteMaximumSpeed,
                max(
                    maximumModeSpeed(
                        for: candidate.reading,
                        configuration: configuration
                    ),
                    measuredSpeed ?? 0
                )
            )
            let maximumDisplacement = maximumSpeed * elapsed + accuracyAllowance
            guard displacement <= max(25, maximumDisplacement) else {
                closeLastSegment(&result)
                startsNewSegment = true
                continue
            }

            guard let update = state.update(
                candidate: candidate,
                after: elapsed,
                sigmaLimit: configuration.innovationSigma,
                processAcceleration: configuration.processAcceleration
            ) else {
                closeLastSegment(&result)
                startsNewSegment = true
                continue
            }

            lastCandidate = candidate
            lastOutput = update.point
            var output = derivedReading(candidate, point: update.point)
            output.point?.horizontalAccuracy = max(
                candidate.accuracy,
                update.uncertainty
            )
            result.append(output)
        }
        return (result + lowConfidenceBoundaries)
            .sorted(by: deterministicReadingOrder)
    }

    private static func closeLastSegment(
        _ readings: inout [SensorReading]
    ) {
        guard !readings.isEmpty else { return }
        readings[readings.count - 1].trackingSessionEnded = true
    }

    private static func boundaryCandidates(
        from candidates: [Candidate]
    ) -> [Candidate] {
        var result: [Candidate] = []
        var index = 0
        while index < candidates.count {
            guard !candidates[index].isPrecise else {
                index += 1
                continue
            }
            let start = index
            while index < candidates.count, !candidates[index].isPrecise {
                index += 1
            }
            result.append(candidates[start])
            if index - 1 > start {
                result.append(candidates[index - 1])
            }
        }
        return result
    }

    private static func maximumModeSpeed(
        for reading: SensorReading,
        configuration: Configuration
    ) -> Double {
        let modeLimit: Double
        switch reading.motion {
        case .walking:
            modeLimit = 4.5
        case .running:
            modeLimit = 9
        case .cycling:
            modeLimit = 25
        case .automotive:
            modeLimit = 90
        case .stationary:
            modeLimit = configuration.stationarySpeed
        case .unknown:
            modeLimit = configuration.maximumPlausibleSpeed
        }
        return modeLimit
    }

    private static func deterministicReadingOrder(
        _ lhs: SensorReading,
        _ rhs: SensorReading
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func normalizedCandidates(
        _ readings: [SensorReading],
        configuration: Configuration
    ) -> [Candidate] {
        let candidates = readings.compactMap { reading -> Candidate? in
            guard let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= configuration.maximumDisplayAccuracy
            else { return nil }
            let isPrecise = point.horizontalAccuracy
                <= configuration.maximumPreciseAccuracy
                && reading.locationFixQuality != .approximate
            return Candidate(
                reading: reading,
                point: point,
                accuracy: point.horizontalAccuracy,
                isPrecise: isPrecise
            )
        }
        let grouped = Dictionary(grouping: candidates, by: \.reading.timestamp)
        return grouped.values
            .compactMap { group in
                group.min { lhs, rhs in
                    if lhs.isPrecise != rhs.isPrecise {
                        return lhs.isPrecise
                    }
                    if lhs.accuracy != rhs.accuracy {
                        return lhs.accuracy < rhs.accuracy
                    }
                    if lhs.reading.sequence != rhs.reading.sequence {
                        return (lhs.reading.sequence ?? .max)
                            < (rhs.reading.sequence ?? .max)
                    }
                    return lhs.reading.id.uuidString < rhs.reading.id.uuidString
                }
            }
            .sorted {
                if $0.reading.timestamp != $1.reading.timestamp {
                    return $0.reading.timestamp < $1.reading.timestamp
                }
                return $0.reading.id.uuidString < $1.reading.id.uuidString
            }
    }

    private static func derivedReading(
        _ candidate: Candidate,
        point: GeoPoint
    ) -> SensorReading {
        var reading = candidate.reading
        reading.point = point
        return reading
    }
}

/// Builds a display-only route from archived and live sensor readings.  It
/// never writes to either input collection or changes an `ActualRecord`.
enum RouteTimelineDataEngine {
    static let maximumInterpolationGap: TimeInterval = 15 * 60
    static let sparseConnectionMinimumGap: TimeInterval = 5 * 60
    static let sparseConnectionMaximumDistanceMeters: Double = 1_000
    static let maximumDisplayReadingCount = 4_096
    static let maximumApproximateDisplayAccuracy: Double = 1_000

    private struct DisplayMeterPoint {
        var east: Double
        var north: Double
    }

    static func project(
        selectedDate: Date,
        through timelineDate: Date? = nil,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let requestedCutoff = timelineDate ?? dayEnd
        let cutoff = min(dayEnd, max(dayStart, requestedCutoff))
        let daySpan = TimeSpan(start: dayStart, end: dayEnd)
        let automatic = automaticRecords(
            actuals,
            intersecting: daySpan,
            through: cutoff
        )
        let combinedReadings = readings + liveReadings
        let allDayReadings = (readingsAreNormalized
            ? combinedReadings
            : normalizedReadings(combinedReadings)).filter {
            $0.timestamp >= dayStart && $0.timestamp < dayEnd
        }
        let coordinateIndex = CoordinateIndex(
            readings: allDayReadings,
            includesApproximateLocations: readingsAreNormalized,
            filtersSparseConnections: filtersSparseRouteConnections
        )
        let visibleReadings = allDayReadings.filter {
            $0.timestamp <= cutoff
        }
        let samples = visibleReadings.compactMap { reading -> RouteTimelineSample? in
            guard let point = validPoint(
                from: reading,
                includesApproximateLocations: readingsAreNormalized
            ) else { return nil }
            return RouteTimelineSample(
                id: reading.id,
                timestamp: reading.timestamp,
                point: point,
                category: category(at: reading.timestamp, in: automatic, through: cutoff)
            )
        }
        let selectedCategory = timelineDate.map { _ in
            category(at: cutoff, in: automatic, through: cutoff)
        }
        let coordinateAtCutoff = confirmedSubwayCoordinate(
            at: cutoff,
            in: travel
        ) ?? coordinateIndex.playbackCoordinate(at: cutoff)?.point
        let segments = makeSegments(
            samples: samples,
            coordinateIndex: coordinateIndex,
            actuals: automatic,
            travel: travel,
            cutoff: cutoff,
            selectedCategory: selectedCategory,
            selectedSpan: selectedSpan
        )
        return RouteTimelineProjection(
            selectedDate: selectedDate,
            cutoff: cutoff,
            selectedCategory: selectedCategory,
            samples: samples,
            segments: segments,
            coordinateAtCutoff: coordinateAtCutoff
        )
    }

    static func project(
        selectedDate: Date,
        throughMinute minute: Int?,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let cutoff = minute.map {
            timelineDate(
                selectedDate: selectedDate,
                minute: $0,
                calendar: calendar
            )
        }
        return project(
            selectedDate: selectedDate,
            through: cutoff,
            selectedSpan: selectedSpan,
            actuals: actuals,
            travel: travel,
            readings: readings,
            liveReadings: liveReadings,
            readingsAreNormalized: readingsAreNormalized,
            filtersSparseRouteConnections: filtersSparseRouteConnections,
            calendar: calendar
        )
    }

    static func timelineDate(
        selectedDate: Date,
        minute: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let clampedMinute = min(1_440, max(0, minute))
        if clampedMinute == 1_440 {
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(24 * 60 * 60)
        }
        return calendar.date(
            byAdding: .minute,
            value: clampedMinute,
            to: dayStart
        ) ?? dayStart
    }

    static func normalizedReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        normalizedReadings(readings, includesApproximateLocations: false)
    }

    static func normalizedDisplayReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        normalizedReadings(readings, includesApproximateLocations: true)
    }

    private static func normalizedReadings(
        _ readings: [SensorReading],
        includesApproximateLocations: Bool
    ) -> [SensorReading] {
        let candidates = readings.filter {
            validPoint(
                from: $0,
                includesApproximateLocations: includesApproximateLocations
            ) != nil
        }
        let grouped = Dictionary(grouping: candidates, by: \.timestamp)
        return grouped.values
            .compactMap { $0.min(by: preferredReading) }
            .sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func playbackCoordinate(
        at date: Date,
        inNormalizedReadings readings: [SensorReading]
    ) -> GeoPoint? {
        guard let first = readings.first,
              validPoint(
                from: first,
                includesApproximateLocations: true
              ) != nil else { return nil }

        // A route archive can begin after the selected timeline time (for
        // example, when only the recent live window has been loaded). Keep
        // the earliest archived/location anchor visible instead of removing
        // the historical marker until a newer sample is available.
        if date < first.timestamp {
            return validPoint(
                from: first,
                includesApproximateLocations: true
            )
        }

        var lower = 0
        var upper = readings.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let beforeIndex = lower - 1
        let before = readings[beforeIndex]
        guard let beforePoint = validPoint(
            from: before,
            includesApproximateLocations: true
        ) else { return nil }
        guard before.timestamp < date else { return beforePoint }
        guard lower < readings.count,
              let afterPoint = validPoint(
                from: readings[lower],
                includesApproximateLocations: true
              ) else {
            return beforePoint
        }
        let gap = readings[lower].timestamp.timeIntervalSince(before.timestamp)
        guard gap > 0 else { return beforePoint }
        return interpolate(
            beforePoint,
            afterPoint,
            ratio: date.timeIntervalSince(before.timestamp) / gap
        )
    }

    static func displayReadings(
        from normalizedReadings: [SensorReading],
        maximumCount: Int = maximumDisplayReadingCount
    ) -> [SensorReading] {
        let maximumCount = max(2, maximumCount)
        guard normalizedReadings.count > maximumCount else {
            return normalizedReadings
        }

        let reduced = reducedDisplayIndices(
            normalizedReadings,
            maximumCount: maximumCount
        )
        let indices: [Int]
        if reduced.count > maximumCount {
            indices = evenlySampledIndices(reduced, count: maximumCount)
        } else {
            var selected = Set(reduced)
            let lastIndex = normalizedReadings.count - 1
            let scale = Double(lastIndex) / Double(maximumCount - 1)
            for outputIndex in 0..<maximumCount where selected.count < maximumCount {
                selected.insert(
                    min(
                        lastIndex,
                        Int((Double(outputIndex) * scale).rounded())
                    )
                )
            }
            if selected.count < maximumCount {
                for index in normalizedReadings.indices {
                    guard selected.count < maximumCount else { break }
                    selected.insert(index)
                }
            }
            indices = selected.sorted()
        }
        return indices.map { normalizedReadings[$0] }
    }

    private static func segmentAwareDisplayIndices(
        _ readings: [SensorReading],
        epsilon: Double
    ) -> [Int] {
        guard readings.count > 1 else { return readings.indices.map { $0 } }
        var result: [Int] = []
        var segmentStart = 0
        for index in 1..<readings.count {
            if startsNewDisplaySegment(
                after: readings[index - 1],
                before: readings[index]
            ) {
                result.append(contentsOf: rdpIndices(
                    readings,
                    lower: segmentStart,
                    upper: index - 1,
                    epsilon: epsilon
                ))
                segmentStart = index
            }
        }
        result.append(contentsOf: rdpIndices(
            readings,
            lower: segmentStart,
            upper: readings.count - 1,
            epsilon: epsilon
        ))
        return result
    }

    private static func reducedDisplayIndices(
        _ readings: [SensorReading],
        maximumCount: Int
    ) -> [Int] {
        let mandatory = mandatoryDisplayIndices(readings)
        func selected(at epsilon: Double) -> Set<Int> {
            Set(segmentAwareDisplayIndices(readings, epsilon: epsilon))
                .union(mandatory)
        }

        var high = 4.0
        while selected(at: high).count > maximumCount, high < 1_000_000 {
            high *= 2
        }
        if selected(at: high).count > maximumCount {
            return mandatory.sorted()
        }

        var low = 0.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if selected(at: middle).count > maximumCount {
                low = middle
            } else {
                high = middle
            }
        }
        return selected(at: high).sorted()
    }

    private static func mandatoryDisplayIndices(
        _ readings: [SensorReading]
    ) -> Set<Int> {
        guard !readings.isEmpty else { return [] }
        var result: Set<Int> = [readings.startIndex, readings.index(before: readings.endIndex)]
        guard readings.count > 2 else { return result }

        for index in 1..<readings.count {
            if startsNewDisplaySegment(
                after: readings[index - 1],
                before: readings[index]
            ) {
                result.insert(index - 1)
                result.insert(index)
            }
        }

        for index in 1..<(readings.count - 1) {
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
        return gap > sparseConnectionMinimumGap
            && distanceMeters(previousPoint, currentPoint)
                > sparseConnectionMaximumDistanceMeters
    }

    private static func rdpIndices(
        _ readings: [SensorReading],
        lower: Int,
        upper: Int,
        epsilon: Double = 4
    ) -> [Int] {
        guard upper >= lower else { return [] }
        guard upper > lower else { return [lower] }
        let origin = readings[lower].point
        let coordinates = (lower...upper).map { index in
            displayMeterPoint(readings[index].point, origin: origin)
        }
        var retained = Set([lower, upper])
        var stack: [(start: Int, end: Int)] = [(0, upper - lower)]
        while let pair = stack.popLast() {
            guard pair.end - pair.start > 1 else { continue }
            let start = coordinates[pair.start]
            let end = coordinates[pair.end]
            var farthestOffset = -1
            var farthestDistance = epsilon
            for offset in (pair.start + 1)..<pair.end {
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
        return retained.sorted()
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
            east: (point.longitude - origin.longitude) * longitudeScale,
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

    private static func evenlySampledIndices(
        _ indices: [Int],
        count: Int
    ) -> [Int] {
        guard count > 1, indices.count > count else { return indices }
        let scale = Double(indices.count - 1) / Double(count - 1)
        return (0..<count).map { outputIndex in
            indices[Int((Double(outputIndex) * scale).rounded())]
        }
    }

    private static func automaticRecords(
        _ actuals: [ActualRecord],
        intersecting day: TimeSpan,
        through cutoff: Date
    ) -> [ActualRecord] {
        actuals.filter { actual in
            guard AutomaticRecordTimelineEngine.isImmutable(actual) else {
                return false
            }
            let overlapsVisibleInterval = actual.startedAt < cutoff
                && (actual.endedAt ?? cutoff) > day.start
                && actual.startedAt < day.end
            let activeAtCutoff = cutoff >= day.start
                && cutoff < day.end
                && actual.startedAt <= cutoff
                && actual.endedAt.map { cutoff < $0 } != false
            return overlapsVisibleInterval || activeAtCutoff
        }
    }

    private static func category(
        at date: Date,
        in actuals: [ActualRecord],
        through cutoff: Date
    ) -> RouteTimelineCategory {
        let candidates = actuals.filter { actual in
            guard actual.startedAt <= date else { return false }
            if let endedAt = actual.endedAt {
                return date < endedAt
            }
            return date <= cutoff
        }
        guard let winner = candidates.max(by: { lowerPriority($0, than: $1) })
        else { return .unconfirmed }
        return RouteTimelineCategory.resolve(
            RecordAnalysisCategoryPolicy.categoryID(for: winner)
        )
    }

    private static func lowerPriority(
        _ lhs: ActualRecord,
        than rhs: ActualRecord
    ) -> Bool {
        let leftCategory = RecordAnalysisCategoryPolicy.categoryID(for: lhs)
        let rightCategory = RecordAnalysisCategoryPolicy.categoryID(for: rhs)
        let leftPhase = DayPhase.phase(forActivityCategory: leftCategory).precedence
        let rightPhase = DayPhase.phase(forActivityCategory: rightCategory).precedence
        if leftPhase != rightPhase { return leftPhase < rightPhase }
        if lhs.manuallyCorrected != rhs.manuallyCorrected {
            return !lhs.manuallyCorrected
        }
        let leftConfidence = confidenceRank(lhs.confidence)
        let rightConfidence = confidenceRank(rhs.confidence)
        if leftConfidence != rightConfidence { return leftConfidence < rightConfidence }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func confidenceRank(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private struct ResolvedCoordinate {
        let point: GeoPoint
        let isInterpolated: Bool
    }

    private struct CoordinateIndex {
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

        func playbackCoordinate(at date: Date) -> ResolvedCoordinate? {
            resolvedCoordinate(at: date, maximumGap: nil)
        }

        func routeCoordinate(at date: Date) -> ResolvedCoordinate? {
            resolvedCoordinate(at: date, maximumGap: maximumInterpolationGap)
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
                            && gap > sparseConnectionMinimumGap
                            && distanceMeters(before.point, after.point)
                                > sparseConnectionMaximumDistanceMeters) {
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
            maximumGap: TimeInterval?
        ) -> ResolvedCoordinate? {
            guard let first = values.first else { return nil }
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
                confirmedSubwayTravelID: confirmedSubwayTravelID
            )
        }
    }

    private static func interpolate(
        _ lhs: GeoPoint,
        _ rhs: GeoPoint,
        ratio: Double
    ) -> GeoPoint {
        let t = min(1, max(0, ratio))
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return GeoPoint(
            latitude: blend(lhs.latitude, rhs.latitude),
            longitude: blend(lhs.longitude, rhs.longitude),
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
        guard isConfirmedSubway(segment),
              let coordinates = segment.subwayRoute?.coordinates,
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

    private static func confirmedSubwayCoordinate(
        at date: Date,
        in travel: [TravelSegment]
    ) -> GeoPoint? {
        guard let segment = confirmedSubwaySegment(at: date, in: travel) else {
            return nil
        }
        return confirmedSubwayCoordinates(for: segment, through: date).last
    }

    private static func confirmedSubwaySegments(
        in travel: [TravelSegment]
    ) -> [TravelSegment] {
        travel.filter(isConfirmedSubway)
    }

    private static func confirmedSubwaySegment(
        at date: Date,
        in travel: [TravelSegment]
    ) -> TravelSegment? {
        confirmedSubwaySegments(in: travel)
            .filter { $0.span.contains(date) }
            .max { $0.span.start < $1.span.start }
    }

    private static func isConfirmedSubway(_ segment: TravelSegment) -> Bool {
        segment.mode == .subway
            && segment.isConfirmed
            && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
    }

    private static func makeSegments(
        samples: [RouteTimelineSample],
        coordinateIndex: CoordinateIndex,
        actuals: [ActualRecord],
        travel: [TravelSegment],
        cutoff: Date,
        selectedCategory: RouteTimelineCategory?,
        selectedSpan: TimeSpan?
    ) -> [RouteTimelineSegment] {
        guard let first = samples.first, first.timestamp < cutoff else { return [] }
        let interiorBoundaries = (
            samples.map(\.timestamp)
                + actuals.flatMap { actual in
                    [actual.startedAt, actual.endedAt ?? cutoff]
                }
                + confirmedSubwaySegments(in: travel).flatMap {
                    [$0.span.start, $0.span.end]
                }
        ).filter { $0 > first.timestamp && $0 < cutoff }
        let boundaries = Set(
            [first.timestamp, cutoff] + interiorBoundaries
        ).sorted()
        var result: [RouteTimelineSegment] = []
        var accumulator: SegmentAccumulator?
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            guard coordinateIndex.isContinuous(from: start, to: end),
                  let startPoint = coordinateIndex.routeCoordinate(at: start)?.point,
                  let endPoint = coordinateIndex.routeCoordinate(at: end)?.point,
                  !sameLocation(startPoint, endPoint) else { continue }
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let category = category(
                at: midpoint,
                in: actuals,
                through: cutoff
            )
            let confirmedSubwayTravelID = confirmedSubwaySegment(
                at: midpoint,
                in: travel
            )?.id
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
                        : [startPoint, endPoint]
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

    private static func preferredReading(
        _ lhs: SensorReading,
        _ rhs: SensorReading
    ) -> Bool {
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

    private static func validPoint(
        from reading: SensorReading,
        includesApproximateLocations: Bool = false
    ) -> GeoPoint? {
        guard let point = reading.point,
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude) else { return nil }
        let isPrecise = reading.gpsAvailable
            || reading.locationFixQuality == .precise
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
        return lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
