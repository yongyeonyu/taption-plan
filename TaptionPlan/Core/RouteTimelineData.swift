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
        segment.mode == .subway
            && segment.isConfirmed
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
            guard AutomaticRecordTimelineEngine.isSleep(actual) else {
                return nil
            }
            let end = min(actual.endedAt ?? upperBound, upperBound)
            guard end > actual.startedAt else { return nil }
            return TimeSpan(start: actual.startedAt, end: end)
                .intersection(with: day)
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

enum MapHomeWBSPlaybackActivity: Hashable, Sendable {
    case movement
    case stay
}

enum MapHomeWBSPlaybackDirection: Int, CaseIterable, Hashable, Sendable {
    case north = 0
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
    case northWest
}

struct MapHomeWBSResolvedRoute: Hashable, Sendable {
    let legID: String
    let coordinates: [GeoPoint]
}

struct MapHomeWBSPlaybackLeg: Hashable, Sendable {
    let id: String
    let startDate: Date
    let endDate: Date
    let coordinates: [GeoPoint]
    let cumulativeDistances: [Double]
    let segmentLengths: [Double]
    let routePhase: MapHomeWBSRoutePhase
    let activity: MapHomeWBSPlaybackActivity
    let mode: TravelMode?
    let categoryID: String?
    let sourcePlaceID: UUID?
    let targetPlaceID: UUID?

    init(
        id: String,
        startDate: Date,
        endDate: Date,
        coordinates: [GeoPoint],
        routePhase: MapHomeWBSRoutePhase,
        activity: MapHomeWBSPlaybackActivity,
        mode: TravelMode? = nil,
        categoryID: String? = nil,
        sourcePlaceID: UUID? = nil,
        targetPlaceID: UUID? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = max(startDate.addingTimeInterval(0.001), endDate)
        self.coordinates = coordinates
        let cumulativeDistances = Self.distances(for: coordinates)
        self.cumulativeDistances = cumulativeDistances
        self.segmentLengths = zip(
            cumulativeDistances,
            cumulativeDistances.dropFirst()
        ).map { $1 - $0 }
        self.routePhase = routePhase
        self.activity = activity
        self.mode = mode
        self.categoryID = categoryID
        self.sourcePlaceID = sourcePlaceID
        self.targetPlaceID = targetPlaceID
    }

    private static func distances(for coordinates: [GeoPoint]) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: coordinates.count)
        for index in 1..<coordinates.count {
            result[index] = result[index - 1]
                + MapHomeWBSPlaybackProjection.distanceMeters(
                    coordinates[index - 1],
                    coordinates[index]
                )
        }
        return result
    }
}

struct MapHomeWBSPlaybackFrame: Hashable, Sendable {
    let date: Date
    let coordinate: GeoPoint
    let cameraCoordinate: GeoPoint
    let direction: MapHomeWBSPlaybackDirection
    let routePhase: MapHomeWBSRoutePhase
    let activity: MapHomeWBSPlaybackActivity
    let legID: String
    let progress: Double
    let mode: TravelMode?
    let categoryID: String?

    var routePhaseIndex: Int {
        Int((progress * 16).rounded(.down)) % 16
    }

    var stickmanFrameIndex: Int {
        min(23, max(0, Int((progress * 24).rounded(.down))))
    }
}

/// WBS와 같은 불변 일 단위 leg 투영이다. 센서·장소·이동 원본은 만들 때 한 번만
/// 정규화하고 재생 중에는 날짜로 frame만 조회한다.
struct MapHomeWBSPlaybackProjection: Hashable, Sendable {
    static let maximumActualGap: TimeInterval = 15 * 60
    static let lookAheadProgress = 0.01
    private static let frameIndexInterval: TimeInterval = 60

    let selectedDate: Date
    let legs: [MapHomeWBSPlaybackLeg]
    private let legIndicesByMinute: [[Int]]

    private init(selectedDate: Date, legs: [MapHomeWBSPlaybackLeg]) {
        self.selectedDate = selectedDate
        self.legs = legs
        let duration = max(
            0,
            legs.lazy.map(\.endDate).max()?.timeIntervalSince(selectedDate)
                ?? 0
        )
        let bucketCount = max(
            1,
            Int(ceil(duration / Self.frameIndexInterval))
        )
        var index = [[Int]](repeating: [], count: bucketCount)
        for (legIndex, leg) in legs.enumerated() {
            let first = Int(floor(
                leg.startDate.timeIntervalSince(selectedDate)
                    / Self.frameIndexInterval
            ))
            let last = Int(floor(
                (leg.endDate.timeIntervalSince(selectedDate) - 0.000_001)
                    / Self.frameIndexInterval
            ))
            guard last >= 0, first < bucketCount else { continue }
            for bucket in max(0, first)...min(bucketCount - 1, last) {
                index[bucket].append(legIndex)
            }
        }
        legIndicesByMinute = index
    }

    static func == (
        lhs: MapHomeWBSPlaybackProjection,
        rhs: MapHomeWBSPlaybackProjection
    ) -> Bool {
        lhs.selectedDate == rhs.selectedDate && lhs.legs == rhs.legs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(selectedDate)
        hasher.combine(legs)
    }

    static func make(
        selectedDate: Date,
        places: [PlaceStay],
        travel: [TravelSegment],
        readings: [SensorReading],
        expectedRouteRequests: [ExpectedRouteRequest]? = nil,
        resolvedRoutes: [MapHomeWBSResolvedRoute] = [],
        actuals: [ActualRecord] = [],
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let sleepSpans = MapHomeSleepLocationPolicy.spans(
            actuals: actuals,
            confirmedSleepSpans: confirmedSleepSpans,
            sleepSessions: sleepSessions,
            in: day
        )
        let sleepAnchors = MapHomeSleepLocationPolicy.anchors(
            for: sleepSpans,
            readings: readings
        )
        let routesByLegID = Dictionary(
            resolvedRoutes.map { ($0.legID, validCoordinates($0.coordinates)) },
            uniquingKeysWith: { _, latest in latest }
        )
        let locations = resolvedLocations(
            places: places,
            in: day,
            calendar: calendar
        )

        var legs = locations.map { location in
            MapHomeWBSPlaybackLeg(
                id: "stay-\(location.place.id.uuidString)",
                startDate: max(dayStart, location.place.span.start),
                endDate: min(dayEnd, location.place.span.end),
                coordinates: [location.coordinate],
                routePhase: .forecast,
                activity: .stay,
                categoryID: nil,
                sourcePlaceID: location.place.id
            )
        }

        let expectedRequests = expectedRouteRequests
            ?? ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: places,
                readings: readings,
                in: day,
                through: dayEnd
            )
        let forecastMovements = expectedRequests.compactMap {
            request -> MapHomeWBSPlaybackLeg? in
            let legID = "movement-\(request.id.uuidString)"
            let resolved = routesByLegID[legID] ?? []
            let coordinates = resolved.count >= 2
                ? resolved
                : [request.start, request.end]
            guard coordinates.count >= 2,
                  distanceMeters(
                      coordinates[0],
                      coordinates[coordinates.count - 1]
                  ) > 0.1 else { return nil }
            return MapHomeWBSPlaybackLeg(
                id: legID,
                startDate: request.departureDate,
                endDate: request.arrivalDate,
                coordinates: coordinates,
                routePhase: .forecast,
                activity: .movement,
                mode: request.mode,
                categoryID: "movement"
            )
        }
        legs.append(contentsOf: forecastMovements.filter { movement in
            !sleepSpans.contains { sleepSpan in
                sleepSpan.intersection(
                    with: TimeSpan(
                        start: movement.startDate,
                        end: movement.endDate
                    )
                ) != nil
            }
        })

        let trace = readings
            .compactMap { reading -> (SensorReading, GeoPoint)? in
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      reading.timestamp >= dayStart,
                      reading.timestamp < dayEnd,
                      let point = reading.point,
                      reading.gpsAvailable,
                      reading.locationFixQuality != .approximate,
                      point.horizontalAccuracy.isFinite,
                      point.horizontalAccuracy >= 0,
                      point.horizontalAccuracy <= 150,
                      isValid(point) else { return nil }
                return (reading, point)
            }
            .sorted {
                if $0.0.timestamp != $1.0.timestamp {
                    return $0.0.timestamp < $1.0.timestamp
                }
                return $0.0.id.uuidString < $1.0.id.uuidString
            }
        for (source, target) in zip(trace, trace.dropFirst()) {
            let duration = target.0.timestamp.timeIntervalSince(source.0.timestamp)
            guard duration > 0,
                  duration <= maximumActualGap,
                  source.0.trackingSessionEnded != true,
                  calendar.isDate(source.0.timestamp, inSameDayAs: target.0.timestamp) else {
                continue
            }
            let distance = distanceMeters(source.1, target.1)
            guard distance > 0.1,
                  !RouteSparseConnectionPolicy.breaksConnection(
                    gapDuration: duration,
                    distanceMeters: distance
                  ),
                  !sleepSpans.contains(where: { sleepSpan in
                      sleepSpan.intersection(
                          with: TimeSpan(
                              start: source.0.timestamp,
                              end: target.0.timestamp
                          )
                      ) != nil
                  }) else { continue }
            legs.append(
                MapHomeWBSPlaybackLeg(
                    id: "actual-\(source.0.id.uuidString)-\(target.0.id.uuidString)",
                    startDate: source.0.timestamp,
                    endDate: target.0.timestamp,
                    coordinates: [source.1, target.1],
                    routePhase: .actual,
                    activity: .movement,
                    mode: movementMode(source.0, target.0),
                    categoryID: "movement"
                )
            )
        }

        legs.append(contentsOf: sleepSpans.enumerated().compactMap { index, span in
            let point = sleepAnchors.first(where: { $0.span == span })?.point
                ?? locations
                    .min {
                        abs($0.place.span.start.timeIntervalSince(span.start))
                            < abs($1.place.span.start.timeIntervalSince(span.start))
                    }?
                    .coordinate
            guard let point else { return nil }
            let sourcePlaceID = locations
                .first { $0.place.span.contains(span.start) }?
                .place
                .id
            return MapHomeWBSPlaybackLeg(
                id: "sleep-\(index)-\(span.start.timeIntervalSinceReferenceDate)",
                startDate: span.start,
                endDate: span.end,
                coordinates: [point],
                routePhase: .actual,
                activity: .stay,
                categoryID: RouteTimelineCategory.sleep.rawValue,
                sourcePlaceID: sourcePlaceID
            )
        })

        legs.sort {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            let left = priority($0)
            let right = priority($1)
            if left != right { return left > right }
            return $0.id < $1.id
        }
        return Self(selectedDate: dayStart, legs: legs)
    }

    func frame(
        at date: Date,
        preferredForecastLegIDs: Set<String> = []
    ) -> MapHomeWBSPlaybackFrame? {
        guard !legs.isEmpty else { return nil }
        let elapsed = date.timeIntervalSince(selectedDate)
        guard elapsed >= 0 else { return nil }
        let minute = Int(elapsed / Self.frameIndexInterval)
        guard legIndicesByMinute.indices.contains(minute) else { return nil }
        let active = legIndicesByMinute[minute].compactMap { index in
            let leg = legs[index]
            return date >= leg.startDate && date < leg.endDate ? leg : nil
        }
        let preferredForecast = active.filter {
            $0.routePhase == .forecast
                && $0.activity == .movement
                && preferredForecastLegIDs.contains($0.id)
        }
        let sleepStays = active.filter {
            $0.activity == .stay
                && $0.categoryID == RouteTimelineCategory.sleep.rawValue
        }
        let candidates: [MapHomeWBSPlaybackLeg]
        if let sleepStay = sleepStays.max(by: { $0.startDate < $1.startDate }) {
            candidates = [sleepStay]
        } else if preferredForecast.isEmpty {
            candidates = active.filter { $0.activity == .stay || $0.routePhase != .forecast }
        } else {
            candidates = preferredForecast
        }
        guard let leg = candidates.max(by: { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            let left = Self.priority(lhs)
            let right = Self.priority(rhs)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }) else { return nil }
        let duration = max(0.001, leg.endDate.timeIntervalSince(leg.startDate))
        let progress = min(1, max(0, date.timeIntervalSince(leg.startDate) / duration))
        let center = leg.coordinates.first ?? Self.zeroPoint
        let coordinate: GeoPoint
        let next: GeoPoint
        let cameraCoordinate: GeoPoint
        switch leg.activity {
        case .movement:
            coordinate = Self.interpolate(leg, progress: progress)
            next = Self.interpolate(
                leg,
                progress: min(1, progress + Self.lookAheadProgress)
            )
            cameraCoordinate = coordinate
        case .stay:
            coordinate = center
            next = center
            cameraCoordinate = center
        }
        let direction: MapHomeWBSPlaybackDirection
        if Self.sameLocation(coordinate, next) {
            let previous: GeoPoint
            switch leg.activity {
            case .movement:
                previous = Self.interpolate(
                    leg,
                    progress: max(0, progress - Self.lookAheadProgress)
                )
            case .stay:
                previous = center
            }
            direction = Self.direction(from: previous, to: coordinate)
        } else {
            direction = Self.direction(from: coordinate, to: next)
        }
        return MapHomeWBSPlaybackFrame(
            date: date,
            coordinate: coordinate,
            cameraCoordinate: cameraCoordinate,
            direction: direction,
            routePhase: leg.routePhase,
            activity: leg.activity,
            legID: leg.id,
            progress: progress,
            mode: leg.mode,
            categoryID: leg.categoryID
        )
    }

    static func interpolate(
        _ leg: MapHomeWBSPlaybackLeg,
        progress: Double
    ) -> GeoPoint {
        guard let first = leg.coordinates.first else { return zeroPoint }
        guard leg.coordinates.count > 1,
              let total = leg.cumulativeDistances.last,
              total > 0 else { return first }
        let wanted = total * min(1, max(0, progress))
        var lower = 1
        var upper = leg.cumulativeDistances.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if leg.cumulativeDistances[middle] < wanted {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let high = min(max(1, lower), leg.coordinates.count - 1)
        let low = high - 1
        let span = leg.cumulativeDistances[high] - leg.cumulativeDistances[low]
        let local = span > 0
            ? (wanted - leg.cumulativeDistances[low]) / span
            : 0
        return blend(leg.coordinates[low], leg.coordinates[high], ratio: local)
    }

    static func direction(
        from start: GeoPoint,
        to end: GeoPoint
    ) -> MapHomeWBSPlaybackDirection {
        let radians = atan2(
            RouteTimelineLongitude.shortestDelta(
                from: start.longitude,
                to: end.longitude
            )
                * cos((start.latitude + end.latitude) * .pi / 360),
            end.latitude - start.latitude
        )
        let degrees = radians * 180 / .pi
        let normalized = degrees >= 0 ? degrees : degrees + 360
        let slot = Int(floor((normalized + 22.5) / 45)) % 8
        return MapHomeWBSPlaybackDirection(rawValue: slot) ?? .north
    }

    static func distanceMeters(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let firstLatitude = lhs.latitude * .pi / 180
        let secondLatitude = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = RouteTimelineLongitude.shortestDelta(
            from: lhs.longitude,
            to: rhs.longitude
        ) * .pi / 180
        let value = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
    }

    private struct ResolvedLocation {
        let place: PlaceStay
        let coordinate: GeoPoint
    }

    private static func resolvedLocations(
        places: [PlaceStay],
        in day: TimeSpan,
        calendar: Calendar
    ) -> [ResolvedLocation] {
        let ordered = places
            .filter { $0.span.intersection(with: day) != nil }
            .sorted {
                if $0.span.start != $1.span.start { return $0.span.start < $1.span.start }
                return $0.id.uuidString < $1.id.uuidString
            }
        let direct = Dictionary(
            uniqueKeysWithValues: ordered.compactMap { place -> (UUID, GeoPoint)? in
                guard let point = place.point, isValid(point) else { return nil }
                return (place.id, point)
            }
        )
        return ordered.enumerated().compactMap { index, place in
            if let point = direct[place.id] {
                return ResolvedLocation(place: place, coordinate: point)
            }
            let previous = ordered[..<index].reversed().compactMap { direct[$0.id] }.first
            let next = ordered.dropFirst(index + 1).compactMap { direct[$0.id] }.first
            guard let point = representativeCoordinate(previous: previous, next: next)
            else { return nil }
            return ResolvedLocation(place: place, coordinate: point)
        }
    }

    private static func representativeCoordinate(
        previous: GeoPoint?,
        next: GeoPoint?
    ) -> GeoPoint? {
        switch (previous, next) {
        case let (previous?, next?): return blend(previous, next, ratio: 0.5)
        case let (previous?, nil): return previous
        case let (nil, next?): return next
        case (nil, nil): return nil
        }
    }

    private static func validCoordinates(_ values: [GeoPoint]) -> [GeoPoint] {
        values.filter(isValid)
    }

    private static func movementMode(
        _ first: SensorReading,
        _ second: SensorReading
    ) -> TravelMode? {
        let values = [second, first]
        if values.contains(where: {
            $0.matchesRailRoute
                || SubwayWiFiSSID.hasContinuousEvidence(
                    streak: $0.subwayWiFiObservationStreak
                )
        }) { return .subway }
        if values.contains(where: \.matchesPublicTransitRoute) { return .bus }
        if values.contains(where: \.onWater) { return .ship }
        for reading in values {
            switch reading.motion {
            case .walking: return .walking
            case .running: return .running
            case .cycling: return .cycling
            case .automotive: return .car
            case .stationary, .unknown: continue
            }
        }
        return nil
    }


    private static func priority(_ leg: MapHomeWBSPlaybackLeg) -> Int {
        if leg.routePhase == .actual { return 3 }
        return leg.activity == .movement ? 2 : 1
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }

    private static func blend(
        _ start: GeoPoint,
        _ end: GeoPoint,
        ratio: Double
    ) -> GeoPoint {
        let value = min(1, max(0, ratio))
        return GeoPoint(
            latitude: start.latitude + (end.latitude - start.latitude) * value,
            longitude: RouteTimelineLongitude.interpolate(
                from: start.longitude,
                to: end.longitude,
                fraction: value
            ),
            altitude: start.altitude + (end.altitude - start.altitude) * value,
            horizontalAccuracy: max(start.horizontalAccuracy, end.horizontalAccuracy),
            verticalAccuracy: max(start.verticalAccuracy, end.verticalAccuracy)
        )
    }

    private static func sameLocation(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000_000_1
            && abs(RouteTimelineLongitude.shortestDelta(
                from: lhs.longitude,
                to: rhs.longitude
            )) < 0.000_000_1
    }

    private static let zeroPoint = GeoPoint(
        latitude: 0,
        longitude: 0,
        altitude: 0,
        horizontalAccuracy: -1,
        verticalAccuracy: -1
    )
}

enum ExpectedRouteTransport: String, Hashable, Sendable {
    case automobile
    case transit
    case walking
    case direct
}

struct ExpectedRouteRequest: Identifiable, Hashable, Sendable {
    let segmentID: UUID
    let mode: TravelMode
    let transport: ExpectedRouteTransport
    let start: GeoPoint
    let end: GeoPoint
    let departureDate: Date
    let arrivalDate: Date
    let provenance: String
    let confidence: Double

    init(
        segmentID: UUID,
        mode: TravelMode,
        transport: ExpectedRouteTransport,
        start: GeoPoint,
        end: GeoPoint,
        departureDate: Date,
        arrivalDate: Date,
        provenance: String = "expected-route",
        confidence: Double = 0
    ) {
        self.segmentID = segmentID
        self.mode = mode
        self.transport = transport
        self.start = start
        self.end = end
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.provenance = provenance
        self.confidence = min(1, max(0, confidence))
    }

    var id: UUID {
        var seed = Data("expected-route-gap-v1".utf8)
        seed.append(contentsOf: segmentID.uuidString.lowercased().utf8)
        seed.append(0)
        for date in [departureDate, arrivalDate] {
            var bits = date.timeIntervalSince1970.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { seed.append(contentsOf: $0) }
        }
        let digest = Array(SHA256.hash(data: seed).prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

}

struct ExpectedRouteRequestReadingIndex {
    private let readings: [SensorReading]

    init(orderedReadings: [SensorReading]) {
        readings = orderedReadings
    }

    func readings(
        in span: TimeSpan,
        operationCount: inout Int
    ) -> ArraySlice<SensorReading> {
        let lower = lowerBound(span.start, operationCount: &operationCount)
        let upper = upperBound(span.end, operationCount: &operationCount)
        return readings[lower..<upper]
    }

    private func lowerBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = readings.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = readings.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp <= timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

struct ExpectedRouteRequestConfirmedSpanIndex {
    private let spans: [TimeSpan]

    init(
        _ source: [TimeSpan],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        var valid: [TimeSpan] = []
        valid.reserveCapacity(source.count)
        for (index, span) in source.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if span.duration > 0 { valid.append(span) }
        }
        let ordered = try RouteTimelineCancellableSort.sorted(
            valid,
            by: { $0.start < $1.start },
            cancellationCheck: cancellationCheck
        )
        var merged: [TimeSpan] = []
        merged.reserveCapacity(ordered.count)
        for (index, span) in ordered.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = TimeSpan(
                    start: last.start,
                    end: max(last.end, span.end)
                )
            } else {
                merged.append(span)
            }
        }
        spans = merged
    }

    func overlapsPositiveDuration(
        _ span: TimeSpan,
        operationCount: inout Int
    ) -> Bool {
        guard span.start < span.end else { return false }
        var lower = 0
        var upper = spans.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if spans[middle].end <= span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count else { return false }
        operationCount += 1
        return spans[lower].start < span.end
    }
}

private struct ExpectedRouteRequestSessionEndIndex {
    private let timestamps: [Date]

    init(
        orderedReadings: [SensorReading],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        var ended: [Date] = []
        for (index, reading) in orderedReadings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if reading.trackingSessionEnded == true {
                ended.append(reading.timestamp)
            }
        }
        try cancellationCheck()
        timestamps = ended
    }

    func contains(
        from start: Date,
        before end: Date,
        operationCount: inout Int
    ) -> Bool {
        guard start < end else { return false }
        let lower = lowerBound(start, operationCount: &operationCount)
        let upper = lowerBound(end, operationCount: &operationCount)
        return lower < upper
    }

    private func lowerBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if timestamps[middle] < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

/// Produces display-only network-route requests. The returned requests never
/// replace archived GPS points or mutate classified travel segments.
enum ExpectedRouteRequestEngine {
    static let minimumRouteDistanceMeters: Double = 20

    private struct RequestCandidate {
        let segment: TravelSegment
        let request: ExpectedRouteRequest
    }

    private struct DuplicateKey: Hashable {
        let fromPlaceID: UUID?
        let toPlaceID: UUID?
        let mode: String
        let start: Date
        let end: Date
    }

    private struct RequestTimeKey: Hashable {
        let departureDate: Date
        let arrivalDate: Date
    }

    private struct RouteGap {
        let start: GeoPoint
        let end: GeoPoint
        let span: TimeSpan
    }

    private struct AdjacentTravelCandidate {
        let id: UUID
        let mode: RouteTravelMode
        let start: Date
        let end: Date
        let order: Int
    }

    private struct AdjacentTravelChoices {
        private(set) var first: AdjacentTravelCandidate?
        private(set) var second: AdjacentTravelCandidate?

        mutating func include(
            _ candidate: AdjacentTravelCandidate,
            precedes: (AdjacentTravelCandidate, AdjacentTravelCandidate) -> Bool
        ) {
            if let first, first.id == candidate.id {
                if precedes(candidate, first) { self.first = candidate }
                return
            }
            if let second, second.id == candidate.id {
                guard precedes(candidate, second) else { return }
                if let first, precedes(candidate, first) {
                    self.second = first
                    self.first = candidate
                } else {
                    self.second = candidate
                }
                return
            }
            if let first, precedes(candidate, first) {
                second = first
                self.first = candidate
            } else if second == nil || precedes(candidate, second!) {
                second = candidate
            }
        }

        func best(excluding id: UUID) -> AdjacentTravelCandidate? {
            guard let first else { return nil }
            return first.id == id ? second : first
        }
    }

    private struct TravelAdjacencyIndex {
        private let previousByEnd: [AdjacentTravelCandidate]
        private let previousChoices: [AdjacentTravelChoices]
        private let followingByStart: [AdjacentTravelCandidate]
        private let followingChoices: [AdjacentTravelChoices]

        init(
            orderedTravel: [TravelSegment],
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            var candidates: [AdjacentTravelCandidate] = []
            candidates.reserveCapacity(orderedTravel.count)
            for (index, segment) in orderedTravel.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                candidates.append(AdjacentTravelCandidate(
                    id: segment.id,
                    mode: routeMode(for: segment.mode),
                    start: segment.span.start,
                    end: segment.span.end,
                    order: index
                ))
            }
            let previousByEnd = try RouteTimelineCancellableSort.sorted(
                candidates,
                by: {
                    if $0.end != $1.end { return $0.end < $1.end }
                    return $0.order < $1.order
                },
                cancellationCheck: cancellationCheck
            )

            var previous = AdjacentTravelChoices()
            var prefix: [AdjacentTravelChoices] = []
            prefix.reserveCapacity(previousByEnd.count)
            for (index, candidate) in previousByEnd.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                previous.include(candidate, precedes: Self.precedesPrevious)
                prefix.append(previous)
            }

            var following = AdjacentTravelChoices()
            var suffix = Array(
                repeating: AdjacentTravelChoices(),
                count: candidates.count
            )
            for (processed, index) in candidates.indices.reversed().enumerated() {
                if processed.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                following.include(candidates[index], precedes: Self.precedesFollowing)
                suffix[index] = following
            }
            try cancellationCheck()
            self.previousByEnd = previousByEnd
            self.previousChoices = prefix
            self.followingByStart = candidates
            followingChoices = suffix
        }

        func before(
            _ segment: TravelSegment,
            operationCount: inout Int
        ) -> RouteTravelMode {
            let limit = upperBoundEnd(
                segment.span.start,
                operationCount: &operationCount
            )
            operationCount += 1
            guard limit > 0,
                  let candidate = previousChoices[limit - 1]
                    .best(excluding: segment.id) else { return .unknown }
            return candidate.mode
        }

        func after(
            _ segment: TravelSegment,
            operationCount: inout Int
        ) -> RouteTravelMode {
            let index = lowerBoundStart(
                segment.span.end,
                operationCount: &operationCount
            )
            operationCount += 1
            guard index < followingChoices.count,
                  let candidate = followingChoices[index]
                    .best(excluding: segment.id) else { return .unknown }
            return candidate.mode
        }

        private func upperBoundEnd(
            _ date: Date,
            operationCount: inout Int
        ) -> Int {
            var lower = 0
            var upper = previousByEnd.count
            while lower < upper {
                operationCount += 1
                let middle = lower + (upper - lower) / 2
                if previousByEnd[middle].end <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func lowerBoundStart(
            _ date: Date,
            operationCount: inout Int
        ) -> Int {
            var lower = 0
            var upper = followingChoices.count
            while lower < upper {
                operationCount += 1
                let middle = lower + (upper - lower) / 2
                if followingByStart[middle].start < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private static func precedesPrevious(
            _ lhs: AdjacentTravelCandidate,
            _ rhs: AdjacentTravelCandidate
        ) -> Bool {
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.order < rhs.order
        }

        private static func precedesFollowing(
            _ lhs: AdjacentTravelCandidate,
            _ rhs: AdjacentTravelCandidate
        ) -> Bool {
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.order < rhs.order
        }
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace] = []
    ) -> [ExpectedRouteRequest] {
        var ignoredOperationCount = 0
        return requests(
            travel: travel,
            places: [],
            readings: readings,
            in: day,
            through: cutoff,
            frequentPlaces: [],
            operationCount: &ignoredOperationCount
        )
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace],
        operationCount: inout Int
    ) -> [ExpectedRouteRequest] {
        (try? requests(
            travel: travel,
            places: [],
            readings: readings,
            in: day,
            through: cutoff,
            frequentPlaces: [],
            operationCount: &operationCount,
            cancellationCheck: { try Task.checkCancellation() }
        )) ?? []
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) throws -> [ExpectedRouteRequest] {
        operationCount = 0
        try cancellationCheck()
        var filteredReadings: [SensorReading] = []
        filteredReadings.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            guard RouteTimelineTimestamp.isValid(reading.timestamp),
                  reading.timestamp >= day.start,
                  reading.timestamp <= day.end else { continue }
            filteredReadings.append(reading)
        }
        try cancellationCheck()
        let orderedReadings = try RouteTimelineCancellableSort.sorted(
            filteredReadings,
            by: {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
        let readingIndex = ExpectedRouteRequestReadingIndex(
            orderedReadings: orderedReadings
        )
        let sessionEndIndex = try ExpectedRouteRequestSessionEndIndex(
            orderedReadings: orderedReadings,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )

        let uniqueTravel = try deduplicated(
            travel,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        let orderedTravel = try RouteTimelineCancellableSort.sorted(
            uniqueTravel,
            by: { $0.span.start < $1.span.start },
            cancellationCheck: cancellationCheck
        )
        var confirmedSourceSpans: [TimeSpan] = []
        confirmedSourceSpans.reserveCapacity(travel.count)
        for (index, segment) in travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if segment.isConfirmed {
                confirmedSourceSpans.append(segment.span)
            }
        }
        let confirmedSpans = try ExpectedRouteRequestConfirmedSpanIndex(
            confirmedSourceSpans,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        let adjacentTravel = try TravelAdjacencyIndex(
            orderedTravel: orderedTravel,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        var candidates: [RequestCandidate] = []

        for (index, segment) in orderedTravel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            guard segment.span.intersection(with: day) != nil,
                  segment.span.start < cutoff,
                  let transport = transport(for: segment),
                  !segment.isConfirmed else { continue }

            let visibleEnd = min(segment.span.end, cutoff)
            guard segment.span.start < visibleEnd else { continue }
            let visibleSpan = TimeSpan(
                start: max(segment.span.start, day.start),
                end: min(visibleEnd, day.end)
            )
            let readingsInSegment = readingIndex.readings(
                in: visibleSpan,
                operationCount: &operationCount
            )
            let gaps = try missingRouteGaps(
                readings: readingsInSegment,
                sessionEndIndex: sessionEndIndex,
                operationCount: &operationCount,
                cancellationCheck: cancellationCheck
            )
            guard !gaps.isEmpty else { continue }
            let precedingMode = adjacentTravel.before(
                segment,
                operationCount: &operationCount
            )
            let followingMode = adjacentTravel.after(
                segment,
                operationCount: &operationCount
            )

            for gap in gaps {
                try cancellationCheck()
                operationCount += 1
                guard distanceMeters(gap.start, gap.end)
                        >= minimumRouteDistanceMeters,
                      !confirmedSpans.overlapsPositiveDuration(
                        gap.span,
                        operationCount: &operationCount
                      ) else { continue }
                let gapReadings = readingIndex.readings(
                    in: gap.span,
                    operationCount: &operationCount
                )
                var samples: [SensorReading] = []
                samples.reserveCapacity(gapReadings.count)
                for (index, reading) in gapReadings.enumerated() {
                    if index.isMultiple(of: 256) { try cancellationCheck() }
                    operationCount += 1
                    if reliableLocationReading(reading) { samples.append(reading) }
                }
                let inference = RouteGapInferenceEngine().infer(.init(
                    start: gap.span.start,
                    end: gap.span.end,
                    startCoordinate: RouteCoordinate(
                        latitude: gap.start.latitude,
                        longitude: gap.start.longitude
                    ),
                    endCoordinate: RouteCoordinate(
                        latitude: gap.end.latitude,
                        longitude: gap.end.longitude
                    ),
                    samples: try TaptionRouteEngineAdapter.samples(
                        from: samples,
                        cancellationCheck: cancellationCheck
                    ),
                    precedingMode: precedingMode,
                    followingMode: followingMode,
                    explicitMode: routeMode(for: segment.mode),
                    endpointConfidence: min(
                        endpointConfidence(gap.start),
                        endpointConfidence(gap.end)
                    )
                ))
                guard inference.allowsConnection else { continue }
                candidates.append(RequestCandidate(
                    segment: segment,
                    request: ExpectedRouteRequest(
                        segmentID: segment.id,
                        mode: segment.mode,
                        transport: transport,
                        start: gap.start,
                        end: gap.end,
                        departureDate: gap.span.start,
                        arrivalDate: gap.span.end,
                        provenance: inference.provenance,
                        confidence: inference.confidence
                    )
                ))
            }
        }
        let uniqueCandidates = try deduplicatedRequests(
            candidates,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        var requests: [ExpectedRouteRequest] = []
        requests.reserveCapacity(uniqueCandidates.count)
        for (index, candidate) in uniqueCandidates.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            requests.append(candidate.request)
        }
        return try RouteTimelineCancellableSort.sorted(
            requests,
            by: {
                if $0.departureDate != $1.departureDate {
                    return $0.departureDate < $1.departureDate
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }

    private static func transport(
        for segment: TravelSegment
    ) -> ExpectedRouteTransport? {
        switch segment.mode {
        case .car, .taxi:
            .automobile
        case .bus, .subway, .train:
            .transit
        case .walking, .running, .cycling:
            .walking
        case .airplane, .ship:
            .direct
        }
    }

    private static func routeMode(for mode: TravelMode) -> RouteTravelMode {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .bus: .bus
        case .subway: .subway
        case .taxi, .car: .automotive
        case .train: .train
        case .airplane: .airplane
        case .ship: .ship
        }
    }

    private static func endpointConfidence(_ point: GeoPoint) -> Double {
        let accuracy = point.horizontalAccuracy
        guard accuracy.isFinite, accuracy >= 0 else { return 0.8 }
        if accuracy <= 20 { return 1 }
        if accuracy <= 100 { return 0.9 }
        if accuracy <= 150 { return 0.75 }
        return 0.5
    }

    private static func reliableLocationReading(
        _ reading: SensorReading
    ) -> Bool {
        guard let point = reading.point else { return false }
        return isValid(point)
            && reading.gpsAvailable
            && reading.locationFixQuality != .approximate
            && point.horizontalAccuracy.isFinite
            && point.horizontalAccuracy >= 0
            && point.horizontalAccuracy <= 150
    }

    private static func missingRouteGaps(
        readings: ArraySlice<SensorReading>,
        sessionEndIndex: ExpectedRouteRequestSessionEndIndex,
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RouteGap] {
        var observed: [SensorReading] = []
        observed.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if RouteTimelineTimestamp.isValid(reading.timestamp),
               reliableLocationReading(reading) {
                observed.append(reading)
            }
        }
        guard observed.count >= 2 else { return [] }
        var gaps: [RouteGap] = []
        for index in 0..<(observed.count - 1) {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            let lhs = observed[index]
            let rhs = observed[index + 1]
            operationCount += 1
            guard let lhsPoint = lhs.point, let rhsPoint = rhs.point else {
                continue
            }
            guard !sessionEndIndex.contains(
                from: lhs.timestamp,
                before: rhs.timestamp,
                operationCount: &operationCount
            ) else { continue }
            let duration = rhs.timestamp.timeIntervalSince(lhs.timestamp)
            guard duration > MapHomeWBSPlaybackProjection.maximumActualGap
                    || RouteSparseConnectionPolicy.breaksConnection(
                        gapDuration: duration,
                        distanceMeters: duration
                                > RouteSparseConnectionPolicy.minimumSparseGapDuration
                            ? distanceMeters(lhsPoint, rhsPoint)
                            : nil
                    )
            else { continue }
            gaps.append(RouteGap(
                start: lhsPoint,
                end: rhsPoint,
                span: TimeSpan(start: lhs.timestamp, end: rhs.timestamp)
            ))
        }
        return gaps
    }

    private static func deduplicated(
        _ travel: [TravelSegment],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [TravelSegment] {
        var selected: [DuplicateKey: TravelSegment] = [:]
        for (index, segment) in travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            let key = DuplicateKey(
                fromPlaceID: segment.fromPlaceID,
                toPlaceID: segment.toPlaceID,
                mode: segment.mode.rawValue,
                start: segment.span.start,
                end: segment.span.end
            )
            guard let current = selected[key] else {
                selected[key] = segment
                continue
            }
            if isRicher(segment, than: current) {
                selected[key] = segment
            }
        }
        var result: [TravelSegment] = []
        result.reserveCapacity(selected.count)
        for (index, segment) in selected.values.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            result.append(segment)
        }
        return result
    }

    private static func deduplicatedRequests(
        _ candidates: [RequestCandidate],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RequestCandidate] {
        var selected: [RequestCandidate] = []
        var indicesByTime: [RequestTimeKey: [Int]] = [:]
        for candidate in candidates {
            operationCount += 1
            if operationCount.isMultiple(of: 256) { try cancellationCheck() }
            let key = RequestTimeKey(
                departureDate: candidate.request.departureDate,
                arrivalDate: candidate.request.arrivalDate
            )
            var matchingIndex: Int?
            for index in indicesByTime[key, default: []] {
                operationCount += 1
                if operationCount.isMultiple(of: 256) { try cancellationCheck() }
                if sameRequestEndpoints(
                    selected[index].request,
                    candidate.request
                ) {
                    matchingIndex = index
                    break
                }
            }
            guard let index = matchingIndex else {
                indicesByTime[key, default: []].append(selected.count)
                selected.append(candidate)
                continue
            }
            if isRicher(candidate.segment, than: selected[index].segment) {
                selected[index] = candidate
            }
        }
        return selected
    }

    private static func sameRequestEndpoints(
        _ lhs: ExpectedRouteRequest,
        _ rhs: ExpectedRouteRequest
    ) -> Bool {
        let sameDirection = distanceMeters(lhs.start, rhs.start) <= 100
            && distanceMeters(lhs.end, rhs.end) <= 100
        let reverseDirection = distanceMeters(lhs.start, rhs.end) <= 100
            && distanceMeters(lhs.end, rhs.start) <= 100
        return sameDirection || reverseDirection
    }

    private static func isRicher(
        _ candidate: TravelSegment,
        than current: TravelSegment
    ) -> Bool {
        let candidateValues = richnessValues(candidate)
        let currentValues = richnessValues(current)
        for index in candidateValues.indices {
            if candidateValues[index] != currentValues[index] {
                return candidateValues[index] > currentValues[index]
            }
        }
        return candidate.id.uuidString < current.id.uuidString
    }

    private static func richnessValues(_ segment: TravelSegment) -> [Int] {
        let confidence = switch segment.confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
        return [
            segment.isConfirmed ? 1 : 0,
            segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
                ? 1
                : 0,
            segment.evidence.count,
            confidence,
        ]
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
    static let maximumDisplayReadingCount = 4_096
    static let maximumApproximateDisplayAccuracy: Double = 1_000

    struct ActualIndex {
        fileprivate let dayStart: Date
        fileprivate let dayEnd: Date
        fileprivate let dayActuals: [ActualRecord]
        fileprivate let automatic: [ActualRecord]
        fileprivate let categories: CategoryIndex

        fileprivate init(
            selectedDate: Date,
            actuals: [ActualRecord],
            calendar: Calendar
        ) {
            let resolvedDayStart = calendar.startOfDay(for: selectedDate)
            let resolvedDayEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: resolvedDayStart
            ) ?? resolvedDayStart.addingTimeInterval(24 * 60 * 60)
            let resolvedDayActuals = actuals.filter { actual in
                actual.startedAt < resolvedDayEnd
                    && (actual.endedAt.map { $0 > resolvedDayStart } ?? true)
            }
            let daySpan = TimeSpan(
                start: resolvedDayStart,
                end: resolvedDayEnd
            )
            let resolvedAutomatic = RouteTimelineDataEngine.automaticRecords(
                resolvedDayActuals,
                intersecting: daySpan,
                through: resolvedDayEnd
            )
            let resolvedCategories = CategoryIndex(
                actuals: resolvedAutomatic,
                dayStart: resolvedDayStart,
                cutoff: resolvedDayEnd
            )
            dayStart = resolvedDayStart
            dayEnd = resolvedDayEnd
            dayActuals = resolvedDayActuals
            automatic = resolvedAutomatic
            categories = resolvedCategories
        }
    }

    static func actualIndex(
        selectedDate: Date,
        actuals: [ActualRecord],
        calendar: Calendar = .autoupdatingCurrent
    ) -> ActualIndex {
        ActualIndex(
            selectedDate: selectedDate,
            actuals: actuals,
            calendar: calendar
        )
    }

    private struct DisplayMeterPoint {
        var east: Double
        var north: Double
    }

    static func project(
        selectedDate: Date,
        through timelineDate: Date? = nil,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        actualIndex cachedActualIndex: ActualIndex? = nil,
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let requestedCutoff = timelineDate ?? dayEnd
        let cutoff = min(dayEnd, max(dayStart, requestedCutoff))
        let daySpan = TimeSpan(start: dayStart, end: dayEnd)
        let actualIndex: ActualIndex
        if let cachedActualIndex,
           cachedActualIndex.dayStart == dayStart,
           cachedActualIndex.dayEnd == dayEnd {
            actualIndex = cachedActualIndex
        } else {
            actualIndex = ActualIndex(
                selectedDate: selectedDate,
                actuals: actuals,
                calendar: calendar
            )
        }
        let dayActuals = actualIndex.dayActuals.filter {
            $0.startedAt <= cutoff
        }
        let automatic = automaticRecords(
            actualIndex.automatic,
            intersecting: daySpan,
            through: cutoff
        )
        let categoryIndex = actualIndex.categories
        let confirmedSubwayIndex = RouteConfirmedSubwayIntervalIndex(
            travel: travel
        )
        let combinedReadings = readings + liveReadings
        let allDayReadings = (readingsAreNormalized
            ? combinedReadings
            : normalizedReadings(combinedReadings)).filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
                && $0.timestamp >= dayStart && $0.timestamp < dayEnd
        }
        let coordinateIndex = CoordinateIndex(
            readings: allDayReadings,
            includesApproximateLocations: readingsAreNormalized,
            filtersSparseConnections: filtersSparseRouteConnections
        )
        let sleepSpans = MapHomeSleepLocationPolicy.spans(
            actuals: dayActuals,
            confirmedSleepSpans: confirmedSleepSpans,
            sleepSessions: sleepSessions,
            in: daySpan,
            through: cutoff
        )
        let sleepAnchors = MapHomeSleepLocationPolicy.anchors(
            for: sleepSpans,
            readings: allDayReadings
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
                category: categoryIndex.category(at: reading.timestamp)
            )
        }
        let selectedCategory = timelineDate.map { _ in
            categoryIndex.category(at: cutoff)
        }
        let coordinateAtCutoff: GeoPoint?
        if let sleepAnchor = MapHomeSleepLocationPolicy.contains(
            cutoff,
            in: sleepAnchors
        )?.point {
            coordinateAtCutoff = sleepAnchor
        } else {
            coordinateAtCutoff = confirmedSubwayCoordinate(
                at: cutoff,
                index: confirmedSubwayIndex
            ) ?? coordinateIndex.playbackCoordinate(
                at: cutoff,
                sleepAnchors: sleepAnchors
            )?.point
        }
        let segments = makeSegments(
            samples: samples,
            coordinateIndex: coordinateIndex,
            actuals: automatic,
            categoryIndex: categoryIndex,
            confirmedSubwayIndex: confirmedSubwayIndex,
            cutoff: cutoff,
            selectedCategory: selectedCategory,
            selectedSpan: selectedSpan,
            sleepSpans: sleepSpans,
            sleepAnchors: sleepAnchors
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
        actualIndex: ActualIndex? = nil,
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
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
            actualIndex: actualIndex,
            travel: travel,
            readings: readings,
            liveReadings: liveReadings,
            readingsAreNormalized: readingsAreNormalized,
            filtersSparseRouteConnections: filtersSparseRouteConnections,
            confirmedSleepSpans: confirmedSleepSpans,
            sleepSessions: sleepSessions,
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
        normalizedReadings(
            readings,
            includesApproximateLocations: false,
            cancellationCheck: {}
        )
    }

    static func normalizedReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try normalizedReadings(
            readings,
            includesApproximateLocations: false,
            cancellationCheck: cancellationCheck
        )
    }

    static func normalizedDisplayReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        normalizedReadings(
            readings,
            includesApproximateLocations: true,
            cancellationCheck: {}
        )
    }

    static func normalizedDisplayReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try normalizedReadings(
            readings,
            includesApproximateLocations: true,
            cancellationCheck: cancellationCheck
        )
    }

    private static func normalizedReadings(
        _ readings: [SensorReading],
        includesApproximateLocations: Bool,
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        var preferredByTimestamp: [Date: SensorReading] = [:]
        preferredByTimestamp.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard RouteTimelineTimestamp.isValid(reading.timestamp),
                  validPoint(
                    from: reading,
                    includesApproximateLocations: includesApproximateLocations
                  ) != nil else { continue }
            if let current = preferredByTimestamp[reading.timestamp] {
                let selected = preferredReading(reading, current)
                    ? reading
                    : current
                if reading.trackingSessionEnded == true
                    || current.trackingSessionEnded == true {
                    var merged = selected
                    merged.trackingSessionEnded = true
                    preferredByTimestamp[reading.timestamp] = merged
                } else {
                    preferredByTimestamp[reading.timestamp] = selected
                }
            } else {
                preferredByTimestamp[reading.timestamp] = reading
            }
        }
        var preferred: [SensorReading] = []
        preferred.reserveCapacity(preferredByTimestamp.count)
        for (index, reading) in preferredByTimestamp.values.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            preferred.append(reading)
        }
        return try RouteTimelineCancellableSort.sorted(
            preferred,
            by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }

    static func playbackCoordinate(
        at date: Date,
        inNormalizedReadings readings: [SensorReading],
        sleepAnchors: [MapHomeSleepLocationAnchor] = []
    ) -> GeoPoint? {
        guard let first = readings.first,
              validPoint(
                from: first,
                includesApproximateLocations: true
              ) != nil else { return nil }
        if let sleepAnchor = MapHomeSleepLocationPolicy.contains(
            date,
            in: sleepAnchors
        )?.point {
            return sleepAnchor
        }

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
        guard gap > 0, gap <= maximumInterpolationGap else {
            return beforePoint
        }
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
        displayReadings(
            from: normalizedReadings,
            maximumCount: maximumCount,
            cancellationCheck: {}
        )
    }

    static func displayReadings(
        from normalizedReadings: [SensorReading],
        maximumCount: Int = maximumDisplayReadingCount,
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        let maximumCount = max(2, maximumCount)
        guard normalizedReadings.count > maximumCount else {
            return normalizedReadings
        }

        let reduced = try reducedDisplayIndices(
            normalizedReadings,
            maximumCount: maximumCount,
            cancellationCheck: cancellationCheck
        )
        let indices: [Int]
        if reduced.count > maximumCount {
            indices = try evenlySampledIndices(
                reduced,
                count: maximumCount,
                cancellationCheck: cancellationCheck
            )
        } else {
            var selected = Set<Int>()
            selected.reserveCapacity(reduced.count)
            for (offset, index) in reduced.enumerated() {
                if offset.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(index)
            }
            let lastIndex = normalizedReadings.count - 1
            let scale = Double(lastIndex) / Double(maximumCount - 1)
            for outputIndex in 0..<maximumCount where selected.count < maximumCount {
                if outputIndex.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(
                    min(
                        lastIndex,
                        Int((Double(outputIndex) * scale).rounded())
                    )
                )
            }
            if selected.count < maximumCount {
                for (offset, index) in normalizedReadings.indices.enumerated() {
                    if offset.isMultiple(of: 256) { try cancellationCheck() }
                    guard selected.count < maximumCount else { break }
                    selected.insert(index)
                }
            }
            indices = try RouteTimelineCancellableSort.sorted(
                try RouteTimelineCancellableSort.collect(
                    selected,
                    cancellationCheck: cancellationCheck
                ),
                by: <,
                cancellationCheck: cancellationCheck
            )
        }
        var result: [SensorReading] = []
        result.reserveCapacity(indices.count)
        for (offset, index) in indices.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            result.append(normalizedReadings[index])
        }
        return result
    }

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

    private static func reducedDisplayIndices(
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

    private static func evenlySampledIndices(
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

    fileprivate struct CategoryIndex {
        private let boundaries: [Date]
        private let categories: [RouteTimelineCategory]

        init(actuals: [ActualRecord], dayStart: Date, cutoff: Date) {
            let starts = actuals.indices.sorted {
                let left = actuals[$0]
                let right = actuals[$1]
                if left.startedAt != right.startedAt {
                    return left.startedAt < right.startedAt
                }
                return left.id.uuidString < right.id.uuidString
            }
            var points = [dayStart, cutoff]
            for actual in actuals where actual.startedAt <= cutoff {
                points.append(max(dayStart, actual.startedAt))
                points.append(max(
                    dayStart,
                    min(cutoff, actual.endedAt ?? cutoff)
                ))
            }
            boundaries = Array(Set(points)).sorted()

            var heap: [Int] = []
            var nextStart = 0
            var builtCategories: [RouteTimelineCategory] = []
            for date in boundaries {
                while nextStart < starts.count,
                      actuals[starts[nextStart]].startedAt <= date {
                    Self.push(starts[nextStart], into: &heap, actuals: actuals)
                    nextStart += 1
                }
                while let winner = heap.first,
                      actuals[winner].endedAt.map({ $0 <= date }) == true {
                    _ = Self.pop(from: &heap, actuals: actuals)
                }
                if let winner = heap.first {
                    builtCategories.append(.resolve(
                        RecordAnalysisCategoryPolicy.categoryID(
                            for: actuals[winner]
                        )
                    ))
                } else {
                    builtCategories.append(.unconfirmed)
                }
            }
            categories = builtCategories
        }

        func category(at date: Date) -> RouteTimelineCategory {
            var lower = 0
            var upper = boundaries.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if boundaries[middle] <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower == 0 ? .unconfirmed : categories[lower - 1]
        }

        private static func push(
            _ index: Int,
            into heap: inout [Int],
            actuals: [ActualRecord]
        ) {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard RouteTimelineDataEngine.lowerPriority(
                    actuals[heap[parent]],
                    than: actuals[heap[child]]
                ) else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        private static func pop(
            from heap: inout [Int],
            actuals: [ActualRecord]
        ) -> Int? {
            guard let first = heap.first else { return nil }
            let last = heap.removeLast()
            guard !heap.isEmpty else { return first }
            heap[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                var highest = left
                if right < heap.count,
                   RouteTimelineDataEngine.lowerPriority(
                       actuals[heap[left]],
                       than: actuals[heap[right]]
                   ) {
                    highest = right
                }
                guard RouteTimelineDataEngine.lowerPriority(
                    actuals[heap[parent]],
                    than: actuals[heap[highest]]
                ) else { break }
                heap.swapAt(parent, highest)
                parent = highest
            }
            return first
        }
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
        index: RouteConfirmedSubwayIntervalIndex
    ) -> GeoPoint? {
        guard let segment = index.segment(at: date) else {
            return nil
        }
        return confirmedSubwayCoordinates(for: segment, through: date).last
    }

    private static func makeSegments(
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

    private static func validPoint(
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
