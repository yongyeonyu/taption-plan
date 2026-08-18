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
}

struct RouteTimelineProjection: Hashable, Sendable {
    let selectedDate: Date
    let cutoff: Date
    let selectedCategory: RouteTimelineCategory?
    let samples: [RouteTimelineSample]
    let segments: [RouteTimelineSegment]
    let coordinateAtCutoff: GeoPoint?
}

/// Builds a display-only route from archived and live sensor readings.  It
/// never writes to either input collection or changes an `ActualRecord`.
enum RouteTimelineDataEngine {
    static let maximumInterpolationGap: TimeInterval = 15 * 60

    static func project(
        selectedDate: Date,
        through timelineDate: Date? = nil,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
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
        let allDayReadings = normalizedReadings(
            readings + liveReadings
        ).filter {
            $0.timestamp >= dayStart && $0.timestamp <= dayEnd
        }
        let visibleReadings = allDayReadings.filter {
            $0.timestamp <= cutoff
        }
        let samples = visibleReadings.compactMap { reading -> RouteTimelineSample? in
            guard let point = validPoint(from: reading) else { return nil }
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
        let coordinateAtCutoff = coordinate(
            at: cutoff,
            in: allDayReadings
        )?.point
        let segments = makeSegments(
            samples: samples,
            allDayReadings: allDayReadings,
            actuals: automatic,
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
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let cutoff: Date? = minute.flatMap {
            calendar.date(
                byAdding: .minute,
                value: min(1_440, max(0, $0)),
                to: calendar.startOfDay(for: selectedDate)
            )
        }
        return project(
            selectedDate: selectedDate,
            through: cutoff,
            selectedSpan: selectedSpan,
            actuals: actuals,
            readings: readings,
            liveReadings: liveReadings,
            calendar: calendar
        )
    }

    static func normalizedReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        let candidates = readings.filter { validPoint(from: $0) != nil }
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

    private static func automaticRecords(
        _ actuals: [ActualRecord],
        intersecting day: TimeSpan,
        through cutoff: Date
    ) -> [ActualRecord] {
        actuals.filter { actual in
            AutomaticRecordTimelineEngine.isImmutable(actual)
                && actual.startedAt < cutoff
                && actual.span(asOf: cutoff).intersection(with: day) != nil
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

    private static func coordinate(
        at date: Date,
        in readings: [SensorReading]
    ) -> ResolvedCoordinate? {
        let values = readings.compactMap { reading -> (Date, GeoPoint)? in
            guard let point = validPoint(from: reading) else { return nil }
            return (reading.timestamp, point)
        }
        guard let first = values.first else { return nil }
        if date <= first.0 { return date == first.0 ? ResolvedCoordinate(point: first.1, isInterpolated: false) : nil }
        guard let beforeIndex = values.lastIndex(where: { $0.0 <= date }) else {
            return nil
        }
        let before = values[beforeIndex]
        guard before.0 < date else {
            return ResolvedCoordinate(point: before.1, isInterpolated: false)
        }
        guard beforeIndex + 1 < values.count else {
            return ResolvedCoordinate(point: before.1, isInterpolated: false)
        }
        let after = values[beforeIndex + 1]
        let gap = after.0.timeIntervalSince(before.0)
        guard gap > 0, gap <= maximumInterpolationGap else {
            return ResolvedCoordinate(point: before.1, isInterpolated: false)
        }
        let ratio = date.timeIntervalSince(before.0) / gap
        return ResolvedCoordinate(
            point: interpolate(before.1, after.1, ratio: ratio),
            isInterpolated: true
        )
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
            altitude: blend(lhs.altitude, rhs.altitude),
            horizontalAccuracy: max(lhs.horizontalAccuracy, rhs.horizontalAccuracy),
            verticalAccuracy: max(lhs.verticalAccuracy, rhs.verticalAccuracy)
        )
    }

    private static func makeSegments(
        samples: [RouteTimelineSample],
        allDayReadings: [SensorReading],
        actuals: [ActualRecord],
        cutoff: Date,
        selectedCategory: RouteTimelineCategory?,
        selectedSpan: TimeSpan?
    ) -> [RouteTimelineSegment] {
        guard let first = samples.first, first.timestamp < cutoff else { return [] }
        let boundaries = Set(
            [first.timestamp, cutoff]
                + samples.map(\.timestamp)
                + actuals.flatMap { actual in
                    [actual.startedAt, actual.endedAt ?? cutoff]
                }
                .filter { $0 > first.timestamp && $0 < cutoff }
        ).sorted()
        var result: [RouteTimelineSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            guard let startPoint = coordinate(at: start, in: allDayReadings)?.point,
                  let endPoint = coordinate(at: end, in: allDayReadings)?.point,
                  !sameLocation(startPoint, endPoint) else { continue }
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let category = category(
                at: midpoint,
                in: actuals,
                through: cutoff
            )
            let opacity: Double
            if let selectedSpan {
                opacity = selectedSpan.contains(midpoint) ? 1.0 : 0.5
            } else {
                opacity = selectedCategory == nil || category == selectedCategory ? 1.0 : 0.5
            }
            append(
                start: start,
                end: end,
                category: category,
                opacity: opacity,
                coordinates: [startPoint, endPoint],
                to: &result
            )
        }
        return result
    }

    private static func append(
        start: Date,
        end: Date,
        category: RouteTimelineCategory,
        opacity: Double,
        coordinates: [GeoPoint],
        to result: inout [RouteTimelineSegment]
    ) {
        guard !coordinates.isEmpty else { return }
        if let last = result.last,
           last.category == category,
           last.opacity == opacity,
           last.end == start {
            var mergedCoordinates = last.coordinates
            for point in coordinates where !sameLocation(mergedCoordinates.last, point) {
                mergedCoordinates.append(point)
            }
            result.removeLast()
            result.append(RouteTimelineSegment(
                id: segmentID(start: last.start, end: end, category: category),
                start: last.start,
                end: end,
                category: category,
                colorHex: category.colorHex,
                opacity: opacity,
                coordinates: mergedCoordinates
            ))
            return
        }
        result.append(RouteTimelineSegment(
            id: segmentID(start: start, end: end, category: category),
            start: start,
            end: end,
            category: category,
            colorHex: category.colorHex,
            opacity: opacity,
            coordinates: coordinates
        ))
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
        let leftAccuracy = lhs.point?.horizontalAccuracy ?? .greatestFiniteMagnitude
        let rightAccuracy = rhs.point?.horizontalAccuracy ?? .greatestFiniteMagnitude
        if leftAccuracy != rightAccuracy { return leftAccuracy < rightAccuracy }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? .max) < (rhs.sequence ?? .max) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validPoint(from reading: SensorReading) -> GeoPoint? {
        guard reading.gpsAvailable, let point = reading.point,
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude) else { return nil }
        return point
    }

    private static func sameLocation(_ lhs: GeoPoint?, _ rhs: GeoPoint?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
