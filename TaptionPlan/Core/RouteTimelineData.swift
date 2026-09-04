import Foundation
import TaptionPlanEngine

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
                guard let point = reading.point, isValid(point) else {
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
        self.cumulativeDistances = Self.distances(for: coordinates)
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
    static let stayRadiusMeters: Double = 30
    static let lookAheadProgress = 0.01

    let selectedDate: Date
    let legs: [MapHomeWBSPlaybackLeg]

    static func make(
        selectedDate: Date,
        places: [PlaceStay],
        travel: [TravelSegment],
        readings: [SensorReading],
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
        let locationsByID = Dictionary(
            uniqueKeysWithValues: locations.map { ($0.place.id, $0) }
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

        var explicitPairs = Set<String>()
        var explicitMovementSpans: [TimeSpan] = []
        var forecastMovements: [MapHomeWBSPlaybackLeg] = []
        let orderedTravel = travel.sorted {
            if $0.span.start != $1.span.start { return $0.span.start < $1.span.start }
            return $0.id.uuidString < $1.id.uuidString
        }
        for segment in orderedTravel {
            guard let overlap = segment.span.intersection(with: day),
                  overlap.duration > 0 else { continue }
            let source = segment.fromPlaceID.flatMap { locationsByID[$0] }
                ?? locations.last { $0.place.span.end <= segment.span.start }
            let target = segment.toPlaceID.flatMap { locationsByID[$0] }
                ?? locations.first { $0.place.span.start >= segment.span.end }
            if TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
                for: segment,
                readings: readings
            ) {
                if let sourceID = source?.place.id, let targetID = target?.place.id {
                    explicitPairs.insert(pairKey(sourceID, targetID))
                }
                explicitMovementSpans.append(overlap)
                continue
            }
            let legID = "movement-\(segment.id.uuidString)"
            let resolved = routesByLegID[legID] ?? []
            let fallback = [source?.coordinate, target?.coordinate].compactMap { $0 }
            let coordinates = resolved.count >= 2
                ? resolved
                : fallback
            guard coordinates.count >= 2,
                  distanceMeters(coordinates[0], coordinates[coordinates.count - 1]) > 0.1
            else { continue }
            if let sourceID = source?.place.id, let targetID = target?.place.id {
                explicitPairs.insert(pairKey(sourceID, targetID))
            }
            let leg = MapHomeWBSPlaybackLeg(
                id: legID,
                startDate: overlap.start,
                endDate: overlap.end,
                coordinates: coordinates,
                routePhase: .forecast,
                activity: .movement,
                mode: segment.mode,
                categoryID: "movement",
                sourcePlaceID: source?.place.id,
                targetPlaceID: target?.place.id
            )
            forecastMovements.append(leg)
            explicitMovementSpans.append(overlap)
        }

        for (source, target) in zip(locations, locations.dropFirst()) {
            guard calendar.isDate(source.place.span.start, inSameDayAs: target.place.span.start),
                  source.place.span.end < target.place.span.start else { continue }
            let key = pairKey(source.place.id, target.place.id)
            guard !explicitPairs.contains(key),
                  distanceMeters(source.coordinate, target.coordinate) > 0.1 else { continue }
            let gap = TimeSpan(
                start: source.place.span.end,
                end: target.place.span.start
            )
            guard !explicitMovementSpans.contains(where: {
                $0.intersection(with: gap) != nil
            }) else { continue }
            let gapReadings = readings.filter {
                $0.timestamp >= gap.start && $0.timestamp <= gap.end
            }
            let preceding = readings
                .filter {
                    $0.timestamp <= gap.start
                        && gap.start.timeIntervalSince($0.timestamp) <= maximumActualGap
                }
                .max { $0.timestamp < $1.timestamp }
            let following = readings
                .filter {
                    $0.timestamp >= gap.end
                        && $0.timestamp.timeIntervalSince(gap.end) <= maximumActualGap
                }
                .min { $0.timestamp < $1.timestamp }
            let inferred = RouteGapInferenceEngine().infer(.init(
                start: gap.start,
                end: gap.end,
                startCoordinate: routeCoordinate(source.coordinate),
                endCoordinate: routeCoordinate(target.coordinate),
                samples: TaptionRouteEngineAdapter.samples(from: gapReadings),
                precedingMode: preceding.map(routeTravelMode) ?? .unknown,
                followingMode: following.map(routeTravelMode) ?? .unknown,
                endpointConfidence: min(
                    endpointConfidence(source),
                    endpointConfidence(target)
                )
            ))
            guard let mode = inferred.mode.flatMap(travelMode) else { continue }
            let legID = "movement-gap-\(source.place.id.uuidString)-\(target.place.id.uuidString)"
            let resolved = routesByLegID[legID] ?? []
            forecastMovements.append(
                MapHomeWBSPlaybackLeg(
                    id: legID,
                    startDate: gap.start,
                    endDate: gap.end,
                    coordinates: resolved.count >= 2
                        ? resolved
                        : [source.coordinate, target.coordinate],
                    routePhase: .forecast,
                    activity: .movement,
                    mode: mode,
                    categoryID: "movement",
                    sourcePlaceID: source.place.id,
                    targetPlaceID: target.place.id
                )
            )
        }

        legs.append(contentsOf: deduplicatedForecastMovements(forecastMovements).filter { movement in
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
                guard reading.timestamp >= dayStart,
                      reading.timestamp < dayEnd,
                      let point = reading.point,
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
                  calendar.isDate(source.0.timestamp, inSameDayAs: target.0.timestamp),
                  distanceMeters(source.1, target.1) > 0.1,
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
        let active = legs.filter { date >= $0.startDate && date < $0.endDate }
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
            if leg.categoryID == RouteTimelineCategory.sleep.rawValue {
                coordinate = center
                next = center
            } else {
                coordinate = Self.orbitCoordinate(around: center, progress: progress)
                next = Self.orbitCoordinate(
                    around: center,
                    progress: min(1, progress + Self.lookAheadProgress)
                )
            }
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
                previous = leg.categoryID == RouteTimelineCategory.sleep.rawValue
                    ? center
                    : Self.orbitCoordinate(
                        around: center,
                        progress: max(0, progress - Self.lookAheadProgress)
                    )
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
            (end.longitude - start.longitude)
                * cos((start.latitude + end.latitude) * .pi / 360),
            end.latitude - start.latitude
        )
        let degrees = radians * 180 / .pi
        let normalized = degrees >= 0 ? degrees : degrees + 360
        let slot = Int(floor((normalized + 22.5) / 45)) % 8
        return MapHomeWBSPlaybackDirection(rawValue: slot) ?? .north
    }

    static func orbitCoordinate(
        around center: GeoPoint,
        progress: Double,
        radiusMeters: Double = stayRadiusMeters
    ) -> GeoPoint {
        let angle = min(1, max(0, progress)) * 2 * .pi
        let metersPerDegreeLatitude = 111_111.0
        let latitude = center.latitude
            + sin(angle) * radiusMeters / metersPerDegreeLatitude
        let metersPerDegreeLongitude = metersPerDegreeLatitude
            * max(0.2, cos(center.latitude * .pi / 180))
        let longitude = center.longitude
            + cos(angle) * radiusMeters / metersPerDegreeLongitude
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: center.altitude,
            horizontalAccuracy: center.horizontalAccuracy,
            verticalAccuracy: center.verticalAccuracy
        )
    }

    static func distanceMeters(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let firstLatitude = lhs.latitude * .pi / 180
        let secondLatitude = rhs.latitude * .pi / 180
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
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
            $0.matchesRailRoute || ($0.subwayWiFiObservationStreak ?? 0) > 0
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

    private static func routeTravelMode(
        _ reading: SensorReading
    ) -> RouteTravelMode {
        if reading.matchesRailRoute
            || (reading.subwayWiFiObservationStreak ?? 0) > 0 {
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

    private static func travelMode(
        _ mode: RouteTravelMode
    ) -> TravelMode? {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .car
        case .privateVehicle: .car
        case .subway: .subway
        case .bus: .bus
        case .train: .train
        case .airplane: .airplane
        case .ship: .ship
        case .unknown: nil
        }
    }

    private static func routeCoordinate(
        _ point: GeoPoint
    ) -> RouteCoordinate {
        RouteCoordinate(latitude: point.latitude, longitude: point.longitude)
    }

    private static func endpointConfidence(
        _ location: ResolvedLocation
    ) -> Double {
        let placeConfidence: Double = switch location.place.confidence {
        case .high: 1
        case .medium: 0.75
        case .low: 0.5
        }
        let accuracy = location.coordinate.horizontalAccuracy
        let accuracyConfidence: Double
        if !accuracy.isFinite || accuracy < 0 {
            accuracyConfidence = 0.75
        } else if accuracy <= 50 {
            accuracyConfidence = 1
        } else if accuracy <= 150 {
            accuracyConfidence = 0.75
        } else {
            accuracyConfidence = 0.4
        }
        return min(placeConfidence, accuracyConfidence)
    }

    private static func pairKey(_ source: UUID, _ target: UUID) -> String {
        "\(source.uuidString.lowercased())->\(target.uuidString.lowercased())"
    }

    private static func deduplicatedForecastMovements(
        _ movements: [MapHomeWBSPlaybackLeg]
    ) -> [MapHomeWBSPlaybackLeg] {
        let ordered = movements.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate > $1.endDate }
            return $0.id < $1.id
        }
        var selected: [(leg: MapHomeWBSPlaybackLeg, coverage: TimeSpan)] = []
        for movement in ordered {
            let span = TimeSpan(start: movement.startDate, end: movement.endDate)
            let conflictingIndices = selected.indices.filter { index in
                selected[index].coverage.intersection(with: span) != nil
                    && sameMovementEndpoints(selected[index].leg, movement)
            }
            guard !conflictingIndices.isEmpty else {
                selected.append((movement, span))
                continue
            }

            var winner = movement
            var coverage = span
            for index in conflictingIndices where prefersForecastMovement(
                selected[index].leg,
                over: winner
            ) {
                winner = selected[index].leg
            }
            for index in conflictingIndices {
                coverage = TimeSpan(
                    start: min(coverage.start, selected[index].coverage.start),
                    end: max(coverage.end, selected[index].coverage.end)
                )
            }
            for index in conflictingIndices.reversed() {
                selected.remove(at: index)
            }
            selected.append((winner, coverage))
        }
        return selected.map { item in
            let leg = item.leg
            guard leg.startDate != item.coverage.start
                    || leg.endDate != item.coverage.end else {
                return leg
            }
            return MapHomeWBSPlaybackLeg(
                id: leg.id,
                startDate: item.coverage.start,
                endDate: item.coverage.end,
                coordinates: leg.coordinates,
                routePhase: leg.routePhase,
                activity: leg.activity,
                mode: leg.mode,
                categoryID: leg.categoryID,
                sourcePlaceID: leg.sourcePlaceID,
                targetPlaceID: leg.targetPlaceID
            )
        }
    }

    private static func sameMovementEndpoints(
        _ lhs: MapHomeWBSPlaybackLeg,
        _ rhs: MapHomeWBSPlaybackLeg
    ) -> Bool {
        if let lhsSource = lhs.sourcePlaceID,
           let lhsTarget = lhs.targetPlaceID,
           let rhsSource = rhs.sourcePlaceID,
           let rhsTarget = rhs.targetPlaceID {
            return (lhsSource == rhsSource && lhsTarget == rhsTarget)
                || (lhsSource == rhsTarget && lhsTarget == rhsSource)
        }
        guard let lhsStart = lhs.coordinates.first,
              let lhsEnd = lhs.coordinates.last,
              let rhsStart = rhs.coordinates.first,
              let rhsEnd = rhs.coordinates.last else { return false }
        let sameDirection = distanceMeters(lhsStart, rhsStart) <= 100
            && distanceMeters(lhsEnd, rhsEnd) <= 100
        let reverseDirection = distanceMeters(lhsStart, rhsEnd) <= 100
            && distanceMeters(lhsEnd, rhsStart) <= 100
        return sameDirection || reverseDirection
    }

    private static func prefersForecastMovement(
        _ candidate: MapHomeWBSPlaybackLeg,
        over current: MapHomeWBSPlaybackLeg
    ) -> Bool {
        let candidateIsGap = candidate.id.hasPrefix("movement-gap-")
        let currentIsGap = current.id.hasPrefix("movement-gap-")
        if candidateIsGap != currentIsGap { return !candidateIsGap }
        if candidate.coordinates.count != current.coordinates.count {
            return candidate.coordinates.count > current.coordinates.count
        }
        let candidateDuration = candidate.endDate.timeIntervalSince(candidate.startDate)
        let currentDuration = current.endDate.timeIntervalSince(current.startDate)
        if candidateDuration != currentDuration {
            return candidateDuration > currentDuration
        }
        return candidate.id < current.id
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
            longitude: start.longitude + (end.longitude - start.longitude) * value,
            altitude: start.altitude + (end.altitude - start.altitude) * value,
            horizontalAccuracy: max(start.horizontalAccuracy, end.horizontalAccuracy),
            verticalAccuracy: max(start.verticalAccuracy, end.verticalAccuracy)
        )
    }

    private static func sameLocation(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000_000_1
            && abs(lhs.longitude - rhs.longitude) < 0.000_000_1
    }

    private static let zeroPoint = GeoPoint(
        latitude: 0,
        longitude: 0,
        altitude: 0,
        horizontalAccuracy: -1,
        verticalAccuracy: -1
    )
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

    var id: UUID { segmentID }
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

    private struct Endpoint {
        let point: GeoPoint
        let usesRegisteredFrequentPlace: Bool
    }

    private struct RouteGap {
        let start: Endpoint
        let end: Endpoint
        let span: TimeSpan
    }

    static func requests(
        travel: [TravelSegment],
        places: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces: [FrequentPlace] = []
    ) -> [ExpectedRouteRequest] {
        let placesByID = places.reduce(into: [UUID: PlaceStay]()) {
            $0[$1.id] = $1
        }
        let frequentPointsByKey = frequentPlaces.reduce(
            into: [String: GeoPoint]()
        ) { result, place in
            guard let point = place.point, isValid(point) else { return }
            result[place.stablePlaceKey] = point
        }
        let orderedReadings = readings
            .filter { reading in
                guard let point = reading.point else { return false }
                return isValid(point)
                    && reading.timestamp >= day.start
                    && reading.timestamp <= day.end
            }
            .sorted { $0.timestamp < $1.timestamp }

        let orderedTravel = deduplicated(travel)
            .sorted { $0.span.start < $1.span.start }
        let candidates: [RequestCandidate] = orderedTravel
            .compactMap { segment in
                guard segment.span.intersection(with: day) != nil,
                      segment.span.start < cutoff,
                      let transport = transport(for: segment),
                      !segment.isConfirmed,
                      !TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
                          for: segment,
                          readings: orderedReadings
                      ),
                      !usesStoredSubwayPath(segment) else { return nil }

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
                guard let gap = largestMissingRouteGap(
                    for: segment,
                    in: visibleSpan,
                    readings: readingsInSegment,
                    placesByID: placesByID,
                    frequentPointsByKey: frequentPointsByKey
                ) else { return nil }
                let start = gap.start
                let end = gap.end
                guard distanceMeters(start.point, end.point)
                        >= minimumRouteDistanceMeters
                else { return nil }
                let inference = RouteGapInferenceEngine().infer(.init(
                    start: gap.span.start,
                    end: gap.span.end,
                    startCoordinate: RouteCoordinate(
                        latitude: start.point.latitude,
                        longitude: start.point.longitude
                    ),
                    endCoordinate: RouteCoordinate(
                        latitude: end.point.latitude,
                        longitude: end.point.longitude
                    ),
                    samples: TaptionRouteEngineAdapter.samples(
                        from: readingsInSegment.filter {
                            reliableLocationReading($0)
                                && $0.timestamp >= gap.span.start
                                && $0.timestamp <= gap.span.end
                        }
                    ),
                    precedingMode: adjacentMode(
                        before: segment,
                        in: orderedTravel
                    ),
                    followingMode: adjacentMode(
                        after: segment,
                        in: orderedTravel
                    ),
                    explicitMode: routeMode(for: segment.mode),
                    endpointConfidence: min(
                        endpointConfidence(start),
                        endpointConfidence(end)
                    )
                ))
                guard inference.allowsConnection else {
                    return nil
                }
                return RequestCandidate(
                    segment: segment,
                    request: ExpectedRouteRequest(
                        segmentID: segment.id,
                        mode: segment.mode,
                        transport: transport,
                        start: start.point,
                        end: end.point,
                        departureDate: gap.span.start,
                        arrivalDate: gap.span.end,
                        provenance: inference.provenance,
                        confidence: inference.confidence
                    )
                )
            }
        return deduplicatedRequests(candidates).map(\.request)
    }

    private static func usesStoredSubwayPath(_ segment: TravelSegment) -> Bool {
        segment.mode == .subway
            && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
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

    private static func adjacentMode(
        before segment: TravelSegment,
        in travel: [TravelSegment]
    ) -> RouteTravelMode {
        travel
            .filter { $0.id != segment.id && $0.span.end <= segment.span.start }
            .max { $0.span.end < $1.span.end }
            .map { routeMode(for: $0.mode) }
            ?? .unknown
    }

    private static func adjacentMode(
        after segment: TravelSegment,
        in travel: [TravelSegment]
    ) -> RouteTravelMode {
        travel
            .filter { $0.id != segment.id && $0.span.start >= segment.span.end }
            .min { $0.span.start < $1.span.start }
            .map { routeMode(for: $0.mode) }
            ?? .unknown
    }

    private static func endpointConfidence(_ endpoint: Endpoint) -> Double {
        if endpoint.usesRegisteredFrequentPlace { return 1 }
        let accuracy = endpoint.point.horizontalAccuracy
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
            && (point.horizontalAccuracy < 0
                || point.horizontalAccuracy <= 150)
    }

    private static func largestMissingRouteGap(
        for segment: TravelSegment,
        in visibleSpan: TimeSpan,
        readings: [SensorReading],
        placesByID: [UUID: PlaceStay],
        frequentPointsByKey: [String: GeoPoint]
    ) -> RouteGap? {
        let observed = readings.filter(reliableLocationReading)
        let start = visibleSpan.start == segment.span.start
            ? placeEndpoint(
                id: segment.fromPlaceID,
                segment: segment,
                placesByID: placesByID,
                frequentPointsByKey: frequentPointsByKey
            )
            : nil
        let end = visibleSpan.end == segment.span.end
            ? placeEndpoint(
                id: segment.toPlaceID,
                segment: segment,
                placesByID: placesByID,
                frequentPointsByKey: frequentPointsByKey
            )
            : nil
        guard let first = observed.first, let last = observed.last else {
            guard let start, let end else { return nil }
            return RouteGap(start: start, end: end, span: visibleSpan)
        }

        var gaps: [RouteGap] = []
        if first.timestamp.timeIntervalSince(visibleSpan.start)
            > MapHomeWBSPlaybackProjection.maximumActualGap,
           let start,
           let point = first.point {
            gaps.append(RouteGap(
                start: start,
                end: Endpoint(
                    point: point,
                    usesRegisteredFrequentPlace: false
                ),
                span: TimeSpan(start: visibleSpan.start, end: first.timestamp)
            ))
        }
        for (lhs, rhs) in zip(observed, observed.dropFirst())
        where rhs.timestamp.timeIntervalSince(lhs.timestamp)
            > MapHomeWBSPlaybackProjection.maximumActualGap {
            guard let lhsPoint = lhs.point, let rhsPoint = rhs.point else {
                continue
            }
            gaps.append(RouteGap(
                start: Endpoint(
                    point: lhsPoint,
                    usesRegisteredFrequentPlace: false
                ),
                end: Endpoint(
                    point: rhsPoint,
                    usesRegisteredFrequentPlace: false
                ),
                span: TimeSpan(start: lhs.timestamp, end: rhs.timestamp)
            ))
        }
        if visibleSpan.end.timeIntervalSince(last.timestamp)
            > MapHomeWBSPlaybackProjection.maximumActualGap,
           let end,
           let point = last.point {
            gaps.append(RouteGap(
                start: Endpoint(
                    point: point,
                    usesRegisteredFrequentPlace: false
                ),
                end: end,
                span: TimeSpan(start: last.timestamp, end: visibleSpan.end)
            ))
        }
        return gaps.max {
            $0.span.duration < $1.span.duration
        }
    }

    private static func placeEndpoint(
        id: UUID?,
        segment: TravelSegment,
        placesByID: [UUID: PlaceStay],
        frequentPointsByKey: [String: GeoPoint]
    ) -> Endpoint? {
        guard let id, let place = placesByID[id] else { return nil }
        if segment.isConfirmed,
           let point = place.point,
           isValid(point) {
            return Endpoint(
                point: point,
                usesRegisteredFrequentPlace: false
            )
        }
        guard segment.isConfirmed || segment.isClassificationLocked,
              let point = frequentPointsByKey[place.placeKey] else {
            return nil
        }
        return Endpoint(
            point: point,
            usesRegisteredFrequentPlace: true
        )
    }

    private static func deduplicated(
        _ travel: [TravelSegment]
    ) -> [TravelSegment] {
        var selected: [DuplicateKey: TravelSegment] = [:]
        for segment in travel {
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
        return Array(selected.values)
    }

    private static func deduplicatedRequests(
        _ candidates: [RequestCandidate]
    ) -> [RequestCandidate] {
        var selected: [(candidate: RequestCandidate, coverage: TimeSpan)] = []
        for candidate in candidates {
            let candidateSpan = TimeSpan(
                start: candidate.request.departureDate,
                end: candidate.request.arrivalDate
            )
            let conflictingIndices = selected.indices.filter { index in
                let current = selected[index]
                return current.coverage.intersection(with: candidateSpan) != nil
                    && sameRequestEndpoints(
                        current.candidate.request,
                        candidate.request
                    )
            }
            guard !conflictingIndices.isEmpty else {
                selected.append((candidate, candidateSpan))
                continue
            }

            var winner = candidate
            var coverage = candidateSpan
            for index in conflictingIndices where isRicher(
                selected[index].candidate.segment,
                than: winner.segment
            ) {
                winner = selected[index].candidate
            }
            for index in conflictingIndices {
                coverage = TimeSpan(
                    start: min(coverage.start, selected[index].coverage.start),
                    end: max(coverage.end, selected[index].coverage.end)
                )
            }
            for index in conflictingIndices.reversed() {
                selected.remove(at: index)
            }
            selected.append((winner, coverage))
        }
        return selected.map { item in
            let candidate = item.candidate
            let request = candidate.request
            guard request.departureDate != item.coverage.start
                    || request.arrivalDate != item.coverage.end else {
                return candidate
            }
            return RequestCandidate(
                segment: candidate.segment,
                request: ExpectedRouteRequest(
                    segmentID: request.segmentID,
                    mode: request.mode,
                    transport: request.transport,
                    start: request.start,
                    end: request.end,
                    departureDate: item.coverage.start,
                    arrivalDate: item.coverage.end,
                    provenance: request.provenance,
                    confidence: request.confidence
                )
            )
        }
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

/// Reduces raw location observations to a deterministic, display-only track.
/// The source readings remain untouched and are still the archive of record.
enum GPSLoggerRouteFilter {
    static func filter(_ readings: [SensorReading]) -> [SensorReading] {
        TaptionRouteEngineAdapter.filteredReadings(from: readings)
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
        let sleepSpans = MapHomeSleepLocationPolicy.spans(
            actuals: actuals,
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
                category: category(at: reading.timestamp, in: automatic, through: cutoff)
            )
        }
        let selectedCategory = timelineDate.map { _ in
            category(at: cutoff, in: automatic, through: cutoff)
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
                in: travel
            ) ?? coordinateIndex.playbackCoordinate(
                at: cutoff,
                sleepAnchors: sleepAnchors
            )?.point
        }
        let segments = makeSegments(
            samples: samples,
            coordinateIndex: coordinateIndex,
            actuals: automatic,
            travel: travel,
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

        func playbackCoordinate(
            at date: Date,
            sleepAnchors: [MapHomeSleepLocationAnchor] = []
        ) -> ResolvedCoordinate? {
            resolvedCoordinate(
                at: date,
                maximumGap: nil,
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
