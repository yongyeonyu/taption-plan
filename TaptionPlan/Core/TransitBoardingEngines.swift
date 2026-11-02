import Foundation
import TaptionPlanEngine

enum TransitBoardingCandidateEngine {
    static let minimumDwell: TimeInterval = 3 * 60
    static let maximumSampleGap: TimeInterval = 5 * 60

    private struct ReadingSpatialIndex {
        private struct Bucket: Hashable {
            let latitude: Int
            let longitude: Int
        }

        private static let bucketDegrees = 0.001
        private let readings: [SensorReading]
        private let buckets: [Bucket: [Int]]

        init(readings: [SensorReading]) {
            self.readings = readings
            var values: [Bucket: [Int]] = [:]
            values.reserveCapacity(readings.count)
            for (index, reading) in readings.enumerated() {
                guard let point = reading.point else { continue }
                let bucket = Bucket(
                    latitude: Self.bucket(for: point.latitude),
                    longitude: Self.bucket(for: point.longitude)
                )
                values[bucket, default: []].append(index)
            }
            buckets = values
        }

        func matchingIndices(for place: TransitBoardingPlace) -> [Int] {
            let radius = max(0, place.radiusMeters)
            let latitudeMetersPerDegree = 110_000.0
            let latitudeDelta = radius / latitudeMetersPerDegree
            let radians = place.point.latitude * .pi / 180
            let longitudeMetersPerDegree = latitudeMetersPerDegree
                * max(abs(cos(radians)), 0.000001)
            let longitudeDelta = radius / longitudeMetersPerDegree
            let minimumLatitude = max(-90, place.point.latitude - latitudeDelta)
            let maximumLatitude = min(90, place.point.latitude + latitudeDelta)
            let minimumLongitude = max(-180, place.point.longitude - longitudeDelta)
            let maximumLongitude = min(180, place.point.longitude + longitudeDelta)
            let lowerLatitude = Self.bucket(for: minimumLatitude)
            let upperLatitude = Self.bucket(for: maximumLatitude)
            let lowerLongitude = Self.bucket(for: minimumLongitude)
            let upperLongitude = Self.bucket(for: maximumLongitude)

            var candidates: [Int] = []
            for latitude in lowerLatitude...upperLatitude {
                for longitude in lowerLongitude...upperLongitude {
                    candidates.append(contentsOf: buckets[Bucket(
                        latitude: latitude,
                        longitude: longitude
                    )] ?? [])
                }
            }
            candidates.sort()
            return candidates.filter { index in
                guard let point = readings[index].point else { return false }
                return distanceMeters(point, place.point) <= radius
            }
        }

        private static func bucket(for coordinate: Double) -> Int {
            Int(floor(coordinate / bucketDegrees))
        }
    }

    static func candidates(
        readings: [SensorReading],
        registeredLocations: [UserTransitLocation],
        nearbyPlaces: [TransitBoardingPlace] = [],
        travel: [TravelSegment] = [],
        decisions: [TransitBoardingDecision] = [],
        through: Date? = nil,
        minimumDwell: TimeInterval = Self.minimumDwell,
        maximumSampleGap: TimeInterval = Self.maximumSampleGap
    ) -> [TransitBoardingCandidate] {
        guard minimumDwell >= 0,
              maximumSampleGap > 0 else { return [] }

        let availableReadings = uniqueReadings(readings)
            .filter { reading in
                guard RouteTimelineTimestamp.isValid(reading.timestamp) else {
                    return false
                }
                guard let through else { return true }
                return reading.timestamp <= through
            }
            .sorted { $0.timestamp < $1.timestamp }
        let orderedReadings = availableReadings
            .filter(isUsableReading)
        guard !orderedReadings.isEmpty else { return [] }
        let availableReadingIndex = SensorEvidenceTimeIndex(
            readings: availableReadings
        )
        let spatialIndex = ReadingSpatialIndex(readings: orderedReadings)
        let travelIndex = TimeSpanValueIndex(travel) { $0.span }
        let places = mergedPlaces(
            registeredLocations: registeredLocations,
            nearbyPlaces: nearbyPlaces,
            readings: orderedReadings
        )
        guard !places.isEmpty else { return [] }

        var result: [TransitBoardingCandidate] = []
        var seenKeys = Set<String>()

        for place in places {
            var groups: [[SensorReading]] = []
            var current: [SensorReading] = []
            var previousIndex: Int?
            for index in spatialIndex.matchingIndices(for: place) {
                let reading = orderedReadings[index]
                guard let last = current.last else {
                    current = [reading]
                    previousIndex = index
                    continue
                }
                let gap = reading.timestamp.timeIntervalSince(last.timestamp)
                if previousIndex.map({ index != $0 + 1 }) == true
                    || gap > maximumSampleGap {
                    groups.append(current)
                    current = [reading]
                } else {
                    current.append(reading)
                }
                previousIndex = index
            }
            if !current.isEmpty { groups.append(current) }

            for group in groups {
                guard let first = group.first,
                      let last = group.last,
                      let point = representativePoint(in: group) else {
                    continue
                }
                let span = TimeSpan(start: first.timestamp, end: last.timestamp)
                guard span.duration >= minimumDwell else { continue }
                let relatedTravel = relatedTravelSegments(
                    to: span,
                    index: travelIndex
                )
                    .filter {
                        qualifiesForBoardingReview(
                            $0,
                            readingIndex: availableReadingIndex,
                            through: through
                        )
                    }
                guard !relatedTravel.isEmpty else { continue }
                guard place.source != .catalog
                        || hasCatalogRailContext(
                            for: place,
                            dwell: span,
                            travel: relatedTravel,
                            readingIndex: availableReadingIndex
                        ) else {
                    continue
                }
                let key = candidateKey(for: place, arrivingAt: first.timestamp)
                let candidate = TransitBoardingCandidate(
                    id: key,
                    placeID: place.id,
                    locationID: place.userLocationID,
                    name: place.name,
                    kind: place.kind,
                    point: point,
                    span: span,
                    dwellDuration: span.duration,
                    source: place.source,
                    travelSegmentIDs: relatedTravel.map(\.id),
                    subwayRoutes: place.kind.boardingMode == .subway
                        ? TransitBoardingDecisionEngine.subwayRoutes(
                            for: relatedTravel, readingIndex: availableReadingIndex)
                        : []
                )
                guard !isSuppressed(candidate, by: decisions),
                      seenKeys.insert(key).inserted else { continue }
                result.append(candidate)
            }
        }

        return deduplicatedCandidates(result)
    }

    static func candidateKey(
        for place: TransitBoardingPlace,
        arrivingAt date: Date
    ) -> String {
        let minute = Int(date.timeIntervalSince1970 / 60)
        return "\(place.id)-\(minute)"
    }

    private static func isSuppressed(
        _ candidate: TransitBoardingCandidate,
        by decisions: [TransitBoardingDecision]
    ) -> Bool {
        decisions.contains { decision in
            if decision.candidateKey == candidate.id {
                return true
            }
            guard decision.mode == nil,
                  let decisionPoint = decision.point,
                  distanceMeters(decisionPoint, candidate.point) <= 100 else {
                return false
            }
            if decision.span.intersection(with: candidate.span) != nil {
                return true
            }
            let gapAfter = candidate.span.start.timeIntervalSince(decision.span.end)
            let gapBefore = decision.span.start.timeIntervalSince(candidate.span.end)
            let nearestGap = max(gapAfter, gapBefore)
            return nearestGap <= maximumSampleGap
        }
    }

    private static func deduplicatedCandidates(
        _ candidates: [TransitBoardingCandidate]
    ) -> [TransitBoardingCandidate] {
        let prioritized = candidates.sorted { lhs, rhs in
            if lhs.dwellDuration != rhs.dwellDuration {
                return lhs.dwellDuration > rhs.dwellDuration
            }
            if lhs.source != rhs.source {
                return sourcePriority(lhs.source) < sourcePriority(rhs.source)
            }
            if lhs.span.start != rhs.span.start {
                return lhs.span.start < rhs.span.start
            }
            return lhs.id < rhs.id
        }

        var unique: [TransitBoardingCandidate] = []
        for candidate in prioritized {
            let isDuplicate = unique.contains { existing in
                existing.kind == candidate.kind
                    && (existing.placeID == candidate.placeID
                        || distanceMeters(existing.point, candidate.point) <= 100)
            }
            if !isDuplicate {
                unique.append(candidate)
            }
        }
        return unique.sorted { $0.span.start < $1.span.start }
    }

    private static func mergedPlaces(
        registeredLocations: [UserTransitLocation],
        nearbyPlaces: [TransitBoardingPlace],
        readings: [SensorReading]
    ) -> [TransitBoardingPlace] {
        let registered = registeredLocations.map(TransitBoardingPlace.init(registered:))
        let mapKitPlaces = nearbyPlaces.filter { place in
            !registered.contains { saved in
                saved.kind == place.kind
                    && distanceMeters(saved.point, place.point)
                        <= max(saved.radiusMeters, 100)
            }
        }
        let preferredPlaces = registered + mapKitPlaces
        let catalogPlaces = catalogPlaces(near: readings).filter { place in
            !preferredPlaces.contains { preferred in
                preferred.kind == place.kind
                    && distanceMeters(preferred.point, place.point)
                        <= max(preferred.radiusMeters, place.radiusMeters)
            }
        }
        return preferredPlaces + catalogPlaces
    }

    private static func catalogPlaces(
        near readings: [SensorReading]
    ) -> [TransitBoardingPlace] {
        var seen = Set<String>()
        var lastProbeAt: Date?
        return readings.compactMap { reading in
            guard lastProbeAt.map({
                reading.timestamp.timeIntervalSince($0) >= 30
            }) ?? true else {
                return nil
            }
            lastProbeAt = reading.timestamp
            guard let point = reading.point,
                  let station = SubwayStationCatalog.nearest(
                    to: point,
                    maximumDistanceMeters: 250
                  ),
                  let stationPoint = station.coordinate else {
                return nil
            }
            let place = TransitBoardingPlace(
                catalogSubwayName: station.stationName,
                point: stationPoint
            )
            guard seen.insert(place.id).inserted else { return nil }
            return place
        }
    }

    private static func hasCatalogRailContext(
        for place: TransitBoardingPlace,
        dwell: TimeSpan,
        travel: [TravelSegment],
        readingIndex: SensorEvidenceTimeIndex
    ) -> Bool {
        if travel.contains(where: { $0.mode == .subway || $0.mode == .train }) {
            return true
        }
        guard let firstTravel = travel.min(by: {
            $0.span.start < $1.span.start
        }),
        let lastTravel = travel.max(by: {
            $0.span.end < $1.span.end
        }) else {
            return false
        }
        let context = TimeSpan(
            start: min(
                dwell.start,
                firstTravel.span.start.addingTimeInterval(-2 * 60)
            ),
            end: max(
                dwell.end,
                lastTravel.span.end.addingTimeInterval(5 * 60)
            )
        )
        let contextReadings = readingIndex.readings(in: context)
        let railMatchCount = contextReadings.filter(\.matchesRailRoute).count
        let railRatio = contextReadings.isEmpty
            ? 0
            : Double(railMatchCount) / Double(contextReadings.count)
        if railMatchCount >= 2 && railRatio >= 0.25 {
            return true
        }
        if SubwayWiFiSSID.hasContinuousEvidence(
            contextReadings.map(\.connectedWiFiSSID)
        ) {
            return true
        }
        let trajectory = SubwayStationCatalog.coordinateTrajectory(
            from: contextReadings
        )
        guard let trajectory else { return false }
        let placeKey = normalizedStationName(place.name)
        return trajectory.observedStationNames.contains {
            normalizedStationName($0) == placeKey
        }
    }

    private static func normalizedStationName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "역", with: "")
            .lowercased()
    }

    private static func sourcePriority(
        _ source: TransitBoardingPlaceSource
    ) -> Int {
        switch source {
        case .registered: 0
        case .catalog: 1
        case .mapKit: 2
        }
    }

    private static func uniqueReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        var seen = Set<UUID>()
        return readings.filter { seen.insert($0.id).inserted }
    }

    private static func isUsableReading(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable,
              reading.locationFixQuality != .approximate,
              let point = reading.point,
              point.latitude.isFinite,
              point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude),
              point.horizontalAccuracy.isFinite,
              point.horizontalAccuracy > 0,
              point.horizontalAccuracy <= 200 else {
            return false
        }
        return true
    }

    private static func representativePoint(
        in readings: [SensorReading]
    ) -> GeoPoint? {
        let points = readings.compactMap(\.point)
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return GeoPoint(
            latitude: points.map(\.latitude).reduce(0, +) / count,
            longitude: points.map(\.longitude).reduce(0, +) / count,
            altitude: points.map(\.altitude).reduce(0, +) / count,
            horizontalAccuracy: points.map(\.horizontalAccuracy).reduce(0, +) / count,
            verticalAccuracy: points.map(\.verticalAccuracy).reduce(0, +) / count
        )
    }

    private static func relatedTravelSegments(
        to span: TimeSpan,
        index: TimeSpanValueIndex<TravelSegment>
    ) -> [TravelSegment] {
        let afterWindow = TimeSpan(
            start: span.end.addingTimeInterval(-2 * 60),
            end: span.end.addingTimeInterval(30 * 60 + 0.001)
        )
        let after = indexedTravelSegments(
            overlapping: afterWindow,
            index: index
        )
            .filter { segment in
                let gap = segment.span.start.timeIntervalSince(span.end)
                return gap >= -2 * 60 && gap <= 30 * 60
            }
            .sorted { $0.span.start < $1.span.start }
        if !after.isEmpty { return after }

        let expanded = TimeSpan(
            start: span.start.addingTimeInterval(-2 * 60),
            end: span.end.addingTimeInterval(30 * 60)
        )
        return indexedTravelSegments(overlapping: expanded, index: index)
            .sorted { $0.span.start < $1.span.start }
    }

    private static func indexedTravelSegments(
        overlapping span: TimeSpan,
        index: TimeSpanValueIndex<TravelSegment>
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return index.values(
            overlapping: span,
            inspectionCount: &inspectionCount
        )
    }

    private static func qualifiesForBoardingReview(
        _ segment: TravelSegment,
        readingIndex: SensorEvidenceTimeIndex,
        through: Date?
    ) -> Bool {
        let segmentReadings = readingIndex.readings(in: segment.span)
        guard !segment.isConfirmed,
              through.map({ segment.span.end <= $0 }) ?? true,
              segment.span.duration > 0,
              isPoweredTravel(segment.mode),
              hasMovementEvidence(segment, readings: segmentReadings) else {
            return false
        }
        let routeComplete = TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
            for: segment,
            readings: segmentReadings
        )
        if segment.confidence == .high && routeComplete {
            return false
        }
        return segment.confidence != .high
            || !segment.isClassificationLocked
            || !routeComplete
    }

    private static func isPoweredTravel(_ mode: TravelMode) -> Bool {
        switch mode {
        case .bus, .subway, .taxi, .car, .train, .airplane, .ship:
            true
        case .walking, .running, .cycling:
            false
        }
    }

    private static func hasMovementEvidence(
        _ segment: TravelSegment,
        readings: [SensorReading]
    ) -> Bool {
        if segment.distanceMeters >= 100 { return true }
        let segmentReadings = readings.filter {
            $0.timestamp >= segment.span.start
                && $0.timestamp <= segment.span.end
        }
        if segmentReadings.contains(where: {
            $0.motion.isMovement || ($0.speedMetersPerSecond ?? 0) >= 1
        }) {
            return true
        }
        let points = segmentReadings.compactMap(\.point)
        let observedDistance = zip(points, points.dropFirst()).reduce(0.0) {
            $0 + distanceMeters($1.0, $1.1)
        }
        return observedDistance >= 100
    }
}

enum TransitBoardingDecisionEngine {
    static func subwayRoutes(
        for segments: [TravelSegment],
        readingIndex: SensorEvidenceTimeIndex
    ) -> [TransitBoardingSubwayRoute] {
        segments.compactMap { segment in
            var confirmed = segment
            confirmed.mode = .subway
            confirmed.isConfirmed = true
            guard let route = SubwayTravelSegmentEngine.confirmedRoute(
                for: confirmed, readingIndex: readingIndex)?.subwayRoute else { return nil }
            return TransitBoardingSubwayRoute(
                travelSegmentID: segment.id, span: segment.span, route: route)
        }
    }

    static func applying(
        _ decisions: [TransitBoardingDecision],
        to segments: [TravelSegment]
    ) -> [TravelSegment] {
        let active = decisions.filter { $0.mode != nil }
        guard !active.isEmpty else { return segments }
        let availableIDs = Set(segments.map(\.id))

        return segments.map { segment in
            guard let decision = active
                .filter({ matches(segment, decision: $0, availableIDs: availableIDs) })
                .max(by: { $0.updatedAt < $1.updatedAt }),
                  let mode = decision.mode else {
                return segment
            }
            var value = segment
            value.mode = mode
            value.confidence = .high
            value.isConfirmed = true
            value.evidence.removeAll { $0.hasPrefix("사용자 확인") }
            value.evidence.append(
                "사용자 확인 · \(MovementPresentation.title(for: mode)) 탑승"
            )
            if mode == .subway, let saved = savedRoute(
                for: segment, decision: decision, availableIDs: availableIDs) {
                value.span = saved.span
                value.subwayRoute = saved.route
                let provenance = "사용자 확정 경로 · 역 좌표 기반 추정"
                if !value.evidence.contains(provenance) { value.evidence.append(provenance) }
            } else if mode != .subway {
                value.subwayRoute = nil
                value.evidence.removeAll { $0.hasPrefix("사용자 확정 경로 ·") }
            }
            return value
        }
    }

    static func removingConfirmations(
        for segments: [TravelSegment],
        from decisions: [TransitBoardingDecision]
    ) -> [TransitBoardingDecision] {
        let ids = Set(segments.map(\.id))
        return decisions.compactMap { decision in
            guard decision.mode != nil else { return decision }
            let savedIDs = Set(segments.compactMap {
                savedRoute(for: $0, decision: decision)?.travelSegmentID
            })
            let removedIDs = ids.union(savedIDs)
            guard decision.travelSegmentIDs.contains(where: removedIDs.contains)
                    || !savedIDs.isEmpty else { return decision }
            var value = decision
            value.travelSegmentIDs.removeAll { removedIDs.contains($0) }
            value.subwayRoutes?.removeAll { removedIDs.contains($0.travelSegmentID) }
            return !value.travelSegmentIDs.isEmpty || value.subwayRoutes?.isEmpty == false
                ? value : nil
        }
    }

    private static func savedRoute(
        for segment: TravelSegment,
        decision: TransitBoardingDecision,
        availableIDs: Set<UUID> = []
    ) -> TransitBoardingSubwayRoute? {
        let routes = (decision.subwayRoutes ?? []).filter {
            sameJourney($0.span, segment.span) && SubwayStationCatalog.isValid($0.route)
        }
        if decision.travelSegmentIDs.contains(segment.id) {
            return routes.first { $0.travelSegmentID == segment.id }
        }
        let missing = routes.filter { !availableIDs.contains($0.travelSegmentID) }
        return missing.count == 1 ? missing[0] : nil
    }

    private static func sameJourney(_ saved: TimeSpan, _ inferred: TimeSpan) -> Bool {
        if saved == inferred { return true }
        guard abs(saved.start.timeIntervalSince(inferred.start)) <= 120,
              abs(saved.end.timeIntervalSince(inferred.end)) <= 120,
              let overlap = saved.intersection(with: inferred) else { return false }
        return overlap.duration / max(1, max(saved.duration, inferred.duration)) >= 0.8
    }

    private static func matches(
        _ segment: TravelSegment,
        decision: TransitBoardingDecision,
        availableIDs: Set<UUID>
    ) -> Bool {
        if decision.travelSegmentIDs.contains(segment.id) { return true }
        return savedRoute(for: segment, decision: decision, availableIDs: availableIDs) != nil
    }
}
