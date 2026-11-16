import Foundation
import CryptoKit
import TaptionPlanEngine

enum RouteTimelineLongitude {
    static func normalized(_ longitude: Double) -> Double {
        let wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }

    static func shortestDelta(from start: Double, to end: Double) -> Double {
        let delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 { return delta - 360 }
        if delta < -180 { return delta + 360 }
        return delta
    }

    static func interpolate(from start: Double, to end: Double, fraction: Double) -> Double {
        let delta = shortestDelta(from: start, to: end)
        let longitude = start + delta * fraction
        if (-180...180).contains(start),
           (-180...180).contains(end),
           (-180...180).contains(longitude),
           delta == end - start {
            return longitude
        }
        return normalized(longitude)
    }
}

enum RouteTimelineTimestamp {
    static func isValid(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= .distantPast
            && date <= .distantFuture
    }
}

struct RouteConfirmedSubwayIntervalIndex {
    private struct Entry {
        let segment: TravelSegment
        let inputOrder: Int
    }

    let segments: [TravelSegment]
    private let leafCount: Int
    private let maximumEndTree: [Date?]

    init(travel: [TravelSegment]) {
        var entries: [Entry] = []
        entries.reserveCapacity(travel.count)
        for (inputOrder, segment) in travel.enumerated()
        where Self.isConfirmedSubway(segment) {
            entries.append(Entry(segment: segment, inputOrder: inputOrder))
        }
        entries.sort {
            if $0.segment.span.start != $1.segment.span.start {
                return $0.segment.span.start < $1.segment.span.start
            }
            return $0.inputOrder > $1.inputOrder
        }
        segments = entries.map(\.segment)

        var leafCount = 1
        while leafCount < entries.count { leafCount *= 2 }
        self.leafCount = leafCount
        var maximumEndTree = Array<Date?>(
            repeating: nil,
            count: leafCount * 2
        )
        for (index, entry) in entries.enumerated() {
            maximumEndTree[leafCount + index] = entry.segment.span.end
        }
        if leafCount > 1 {
            for node in stride(from: leafCount - 1, through: 1, by: -1) {
                maximumEndTree[node] = Self.later(
                    maximumEndTree[node * 2],
                    maximumEndTree[node * 2 + 1]
                )
            }
        }
        self.maximumEndTree = maximumEndTree
    }

    func segment(at date: Date) -> TravelSegment? {
        var operationCount: Int? = nil
        return segment(at: date, operationCount: &operationCount)
    }

    func segment(
        at date: Date,
        operationCount: inout Int
    ) -> TravelSegment? {
        var recordedOperations: Int? = 0
        let result = segment(at: date, operationCount: &recordedOperations)
        operationCount += recordedOperations ?? 0
        return result
    }

    static func isConfirmedSubway(_ segment: TravelSegment) -> Bool {
        hasTrustedSubwayRoute(segment)
            && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
    }

    private func segment(
        at date: Date,
        operationCount: inout Int?
    ) -> TravelSegment? {
        var lower = 0
        var upper = segments.count
        while lower < upper {
            operationCount? += 1
            let middle = lower + (upper - lower) / 2
            if segments[middle].span.start <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0,
              let index = rightmostContainingIndex(
                  in: 1,
                  lower: 0,
                  upper: leafCount,
                  before: lower,
                  date: date,
                  operationCount: &operationCount
              ) else { return nil }
        return segments[index]
    }

    private func rightmostContainingIndex(
        in node: Int,
        lower: Int,
        upper: Int,
        before limit: Int,
        date: Date,
        operationCount: inout Int?
    ) -> Int? {
        operationCount? += 1
        guard lower < limit,
              maximumEndTree[node].map({ $0 >= date }) == true else {
            return nil
        }
        guard upper - lower > 1 else {
            return lower < segments.count ? lower : nil
        }
        let middle = lower + (upper - lower) / 2
        if middle < limit,
           let index = rightmostContainingIndex(
               in: node * 2 + 1,
               lower: middle,
               upper: upper,
               before: limit,
               date: date,
               operationCount: &operationCount
           ) {
            return index
        }
        return rightmostContainingIndex(
            in: node * 2,
            lower: lower,
            upper: middle,
            before: limit,
            date: date,
            operationCount: &operationCount
        )
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }
}

enum RouteTimelineCancellableSort {
    static func collect<Values: Sequence>(
        _ values: Values,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Values.Element] {
        try cancellationCheck()
        var result: [Values.Element] = []
        result.reserveCapacity(values.underestimatedCount)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            result.append(value)
        }
        return result
    }

    static func sorted<Element>(
        _ values: [Element],
        by precedes: (Element, Element) -> Bool,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Element] {
        try cancellationCheck()
        let count = values.count
        guard count > 1 else { return values }

        var source = try collect(
            values,
            cancellationCheck: cancellationCheck
        )
        var destination = try collect(
            source,
            cancellationCheck: cancellationCheck
        )
        var width = 1
        var operations = 0
        while width < count {
            var start = 0
            while start < count {
                let middle = start + min(width, count - start)
                let end = middle + min(width, count - middle)
                var left = start
                var right = middle
                var output = start
                while output < end {
                    operations += 1
                    if operations.isMultiple(of: 256) { try cancellationCheck() }
                    if left < middle,
                       right == end || !precedes(source[right], source[left]) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                start = end
            }
            swap(&source, &destination)
            width = width > count / 2 ? count : width * 2
        }
        try cancellationCheck()
        return source
    }
}

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
    let coordinateTimestamps: [Date]

    init(
        id: String, start: Date, end: Date, category: RouteTimelineCategory,
        colorHex: String, opacity: Double, coordinates: [GeoPoint],
        speedMetersPerSecond: Double?, confirmedSubwayTravelID: UUID?,
        coordinateTimestamps: [Date] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.category = category
        self.colorHex = colorHex
        self.opacity = opacity
        self.coordinates = coordinates
        self.speedMetersPerSecond = speedMetersPerSecond
        self.confirmedSubwayTravelID = confirmedSubwayTravelID
        self.coordinateTimestamps = coordinateTimestamps
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

enum MapHomeWBSRoutePhase: String, Hashable, Sendable {
    case actual
    case forecast
}

struct MapHomeSleepLocationAnchor: Hashable, Sendable {
    let span: TimeSpan
    let point: GeoPoint
}

enum MapHomeSleepLocationPolicy {
    static func spans(
        actuals: [ActualRecord],
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
        in day: TimeSpan,
        through date: Date? = nil
    ) -> [TimeSpan] {
        let upperBound = min(day.end, date ?? day.end)
        guard upperBound > day.start else { return [] }

        let actualSpans = actuals.compactMap { actual -> TimeSpan? in
            let end = min(actual.endedAt ?? upperBound, upperBound)
            guard end > actual.startedAt,
                  let visible = TimeSpan(start: actual.startedAt, end: end)
                    .intersection(with: day),
                  AutomaticRecordTimelineEngine.isSleep(actual) else { return nil }
            return visible
        }
        let sessionSpans = sleepSessions.compactMap { session -> TimeSpan? in
            guard session.asleepDuration > 0 else { return nil }
            return session.span.intersection(with: day)
        }
        let confirmedSpans = confirmedSleepSpans.compactMap { span -> TimeSpan? in
            guard span.duration > 0 else { return nil }
            return span.intersection(with: day)
        }
        return ActualIntervalMergeEngine.union(
            actualSpans + confirmedSpans + sessionSpans,
            mergeGap: 0
        )
    }

    static func anchors(
        for spans: [TimeSpan],
        readings: [SensorReading]
    ) -> [MapHomeSleepLocationAnchor] {
        let ordered = readings
            .compactMap { reading -> (Date, GeoPoint)? in
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      let point = reading.point, isValid(point) else {
                    return nil
                }
                return (reading.timestamp, point)
            }
            .sorted { $0.0 < $1.0 }
        return spans.compactMap { span in
            let point = ordered.last { $0.0 <= span.start }?.1
                ?? ordered.first { $0.0 >= span.start && $0.0 < span.end }?.1
                ?? ordered.first?.1
            guard let point else { return nil }
            return MapHomeSleepLocationAnchor(span: span, point: point)
        }
    }

    static func contains(
        _ date: Date,
        in anchors: [MapHomeSleepLocationAnchor]
    ) -> MapHomeSleepLocationAnchor? {
        anchors.first { $0.span.start <= date && date < $0.span.end }
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}
