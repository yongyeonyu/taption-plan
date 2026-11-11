import Foundation
import TaptionPlanEngine

// 하루 재생 투영: 이동 구간을 시각별 좌표·방향·활동으로 펴는 값들. `RouteTimelineData.swift`에서 옮겼다(RFT1107A01).

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
                + distanceMeters(
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

struct MapHomePlaybackLocation: Equatable {
    let coordinate: GeoPoint
    let cameraCoordinate: GeoPoint

    init(coordinate: GeoPoint, cameraCoordinate: GeoPoint? = nil) {
        self.coordinate = coordinate
        self.cameraCoordinate = cameraCoordinate ?? coordinate
    }

    static func resolve(
        at date: Date,
        frame: MapHomeWBSPlaybackFrame?,
        normalizedReadings: [SensorReading],
        confirmedTravel: [TravelSegment] = [],
        expectedCoordinate: GeoPoint? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self? {
        // 지하철은 확정 여부와 상관없이 노선 위에 올린다. 자동 분류 구간은 `isConfirmed`가
        // 늘 false라, 예전에는 노선이 그려져 있어도 화랑이가 그 구간에서 사라졌다.
        // 탑승 중에는 GPS 두 점을 직선으로 이은 프레임보다 선로가 먼저다(SUB1108A01).
        let subwayPoint = Self.subwayCoordinate(at: date, travel: confirmedTravel, readings: normalizedReadings)
        if subwayPoint == nil, let frame, frame.date == date {
            return Self(coordinate: frame.coordinate, cameraCoordinate: frame.cameraCoordinate)
        }
        if let point = subwayPoint ?? expectedCoordinate {
            return Self(coordinate: point)
        }
        // The prepared readings belong to one day and are sorted. Query that
        // day's evidence directly; a rendered route or an earlier frame can lag.
        guard let first = normalizedReadings.first,
              date >= first.timestamp,
              calendar.isDate(first.timestamp, inSameDayAs: date),
              let point = RouteTimelineDataEngine.playbackCoordinate(
                at: date,
                inNormalizedReadings: normalizedReadings
              ) else { return nil }
        return Self(coordinate: point)
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
        gpsLoggingInterval: TimeInterval = GPSLoggingPreferences.standard.interval,
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
                through: dayEnd,
                gpsLoggingInterval: gpsLoggingInterval
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
                    mode: MapHomePlaybackLocation.ridingMode(movementMode(source.0, target.0), at: source.0.timestamp, travel: travel),
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
        var candidates: [MapHomeWBSPlaybackLeg]
        if let sleepStay = sleepStays.max(by: { $0.startDate < $1.startDate }) {
            candidates = [sleepStay]
        } else if preferredForecast.isEmpty {
            candidates = active.filter { $0.activity == .stay || $0.routePhase != .forecast }
            // 표시 중인 예상 경로가 없어도 그 시각에 움직이는 예상 구간밖에 없다면
            // 화랑이를 숨기지 않는다. 확정된 장소가 아직 없는 미확정 경로에서 캐릭터가
            // 통째로 사라지던 문제를 막는다. 확정 체류가 하나라도 있으면 위 후보가
            // 비지 않으므로 숨은 경로를 걷는 동작은 그대로 유지된다.
            if candidates.isEmpty {
                candidates = active
            }
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
            ordered.compactMap { place -> (UUID, GeoPoint)? in
                guard let point = place.point, isValid(point) else { return nil }
                return (place.id, point)
            },
            uniquingKeysWith: { first, _ in first }
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

