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
    let confirmedSubwayTravelID: UUID?
}

struct RouteTimelineProjection: Hashable, Sendable {
    let selectedDate: Date
    let cutoff: Date
    let selectedCategory: RouteTimelineCategory?
    let samples: [RouteTimelineSample]
    let segments: [RouteTimelineSegment]
    let coordinateAtCutoff: GeoPoint?
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
    static let endpointSearchMargin: TimeInterval = 15 * 60
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
                        .addingTimeInterval(-endpointSearchMargin)
                    && reading.timestamp <= day.end
                        .addingTimeInterval(endpointSearchMargin)
            }
            .sorted { $0.timestamp < $1.timestamp }

        return travel
            .sorted { $0.span.start < $1.span.start }
            .compactMap { segment in
                guard segment.span.intersection(with: day) != nil,
                      segment.span.start < cutoff,
                      let transport = transport(for: segment),
                      !usesStoredSubwayPath(segment) else { return nil }

                let visibleEnd = min(segment.span.end, cutoff)
                guard segment.span.start < visibleEnd else { return nil }
                let visibleSpan = TimeSpan(
                    start: max(segment.span.start, day.start),
                    end: min(visibleEnd, day.end)
                )
                let readingsInSegment = orderedReadings.filter {
                    $0.timestamp >= visibleSpan.start
                        .addingTimeInterval(-endpointSearchMargin)
                        && $0.timestamp <= visibleSpan.end
                            .addingTimeInterval(endpointSearchMargin)
                }

                let start = segment.fromPlaceID
                    .flatMap { placesByID[$0]?.point }
                    .flatMap { isValid($0) ? $0 : nil }
                    ?? nearestPoint(
                        to: visibleSpan.start,
                        in: readingsInSegment
                    )
                let end: GeoPoint?
                if visibleEnd < segment.span.end {
                    end = readingsInSegment
                        .last(where: { $0.timestamp <= visibleEnd })?
                        .point
                } else {
                    end = segment.toPlaceID
                        .flatMap { placesByID[$0]?.point }
                        .flatMap { isValid($0) ? $0 : nil }
                        ?? nearestPoint(
                            to: visibleSpan.end,
                            in: readingsInSegment
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

    private static func nearestPoint(
        to date: Date,
        in readings: [SensorReading]
    ) -> GeoPoint? {
        readings.min {
            abs($0.timestamp.timeIntervalSince(date))
                < abs($1.timestamp.timeIntervalSince(date))
        }?.point
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
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
              ) != nil,
              date >= first.timestamp else { return nil }

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
        let lastIndex = normalizedReadings.count - 1
        let scale = Double(lastIndex) / Double(maximumCount - 1)
        return (0..<maximumCount).map { outputIndex in
            let sourceIndex = min(
                lastIndex,
                Int((Double(outputIndex) * scale).rounded())
            )
            return normalizedReadings[sourceIndex]
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
        private let values: [(timestamp: Date, point: GeoPoint)]
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
                return (reading.timestamp, point)
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
                    if gap > maximumInterpolationGap
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
            if date < first.timestamp { return nil }

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
            guard gap > 0,
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
               current.end == start {
                current.end = end
                if !sameLocation(current.coordinates.last, endPoint) {
                    current.coordinates.append(endPoint)
                }
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
            && reading.locationFixQuality == .approximate
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
