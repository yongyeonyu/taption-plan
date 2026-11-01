import CoreLocation
import Foundation
import MapKit
import TaptionPlanCore

actor PlaceNameResolver {
    func displayName(
        latitude: Double,
        longitude: Double
    ) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            ) { placemarks, _ in
                let place = placemarks?.first
                let name = place?.areasOfInterest?.first
                    ?? place?.name
                    ?? place?.locality
                continuation.resume(returning: name)
            }
        }
    }
}

struct AppleTransportContext: Hashable, Sendable {
    static let subwayMatchRadiusMeters = 450.0
    static let busStopMatchRadiusMeters = 140.0
    static let roadEvidenceRadiusMeters = 1_500.0

    var subwayStationName: String?
    var busStopName: String?
    var isOnRoad = false

    var isNearSubwayStation: Bool { subwayStationName != nil }
    var isNearBusStop: Bool { busStopName != nil }

    func propagated(toDistanceFromAnchor distance: Double) -> Self? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let subway = distance <= Self.subwayMatchRadiusMeters
            ? subwayStationName
            : nil
        let bus = distance <= Self.busStopMatchRadiusMeters
            ? busStopName
            : nil
        let road = isOnRoad && distance <= Self.roadEvidenceRadiusMeters
        guard subway != nil || bus != nil || road else { return nil }
        return Self(
            subwayStationName: subway,
            busStopName: bus,
            isOnRoad: road
        )
    }
}

@MainActor
final class AppleTransportContextService {
    /// Bump when persisted raw sensor readings need a fresh transport
    /// enrichment pass even if their archive fingerprint is unchanged.
    static let enrichmentModelVersion = 5

    /// Apple 지하철 POI 검색 반경(450m)과 사내 역 카탈로그 매칭 반경을
    /// 일치시킨다. 두 값이 어긋나면 Apple은 역을 찾았는데 카탈로그는
    /// 못 찾는 구간이 생겨 `nearbyStationName`이 영구히 비고, 그 결과
    /// 지하철 증거(`SubwayRouteEvidence`)가 한 번도 만들어지지 않는다.
    private static let stationMatchRadiusMeters =
        AppleTransportContext.subwayMatchRadiusMeters

    private struct CacheEntry {
        let context: AppleTransportContext
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    func enriching(
        _ readings: [SensorReading],
        userTransitLocations: [UserTransitLocation] = []
    ) async -> [SensorReading] {
        let userEnriched = readings.map {
            applyingUserTransitLocations($0, locations: userTransitLocations)
        }
        let staticOnly = readings.indices.filter { index in
            guard let point = userEnriched[index].point,
                  SubwayStationCatalog.nearest(
                      to: point,
                      maximumDistanceMeters: Self.stationMatchRadiusMeters
                  ) != nil else { return false }
            let reading = userEnriched[index]
            return reading.motion != .stationary
                || (reading.speedMetersPerSecond ?? 0) >= 1
                || !reading.gpsAvailable
                || reading.nearbyStation
        }
        let candidates = readings.indices.filter { index in
            guard userEnriched[index].point != nil else { return false }
            return userEnriched[index].motion == .automotive
                || (userEnriched[index].speedMetersPerSecond ?? 0) >= 3
        }
        guard candidates.count >= 1 || staticOnly.count >= 1 else {
            return deterministicStationJourneyEnrichment(
                userEnriched.map(refiningStaticStation)
            )
        }

        let anchors = sampledIndices(
            candidates.isEmpty ? staticOnly : candidates,
            maximumCount: 4
        )
        var resolved: [(GeoPoint, AppleTransportContext)] = []
        for index in anchors {
            guard let point = readings[index].point else { continue }
            resolved.append((point, await context(at: point)))
        }
        guard !resolved.isEmpty else {
            return deterministicStationJourneyEnrichment(
                userEnriched.map(refiningStaticStation)
            )
        }

        let enriched = userEnriched.map { reading in
            let reading = refiningStaticStation(reading)
            guard let point = reading.point,
                  let match = resolved.min(by: {
                      distanceMeters(point, $0.0) < distanceMeters(point, $1.0)
                  }),
                  let context = match.1.propagated(
                      toDistanceFromAnchor: distanceMeters(point, match.0)
                  ) else {
                return reading
            }
            var value = reading
            value.nearbyStation = value.nearbyStation
                || context.isNearSubwayStation
                || context.isNearBusStop
            if let stationName = context.subwayStationName
                ?? context.busStopName {
                value.nearbyStationName = stationName
            }
            value.matchesPublicTransitRoute =
                value.matchesPublicTransitRoute || context.isNearBusStop
            // MapKit 검색이 누락되거나 역 이름을 잘못 붙여도, 공식 역
            // 카탈로그의 좌표를 마지막 보정으로 사용한다. 버스 정류장
            // 표본은 철도 역으로 승격하지 않는다.
            if value.matchesRailRoute,
               let station = SubwayStationCatalog.nearest(
                   to: point,
                   maximumDistanceMeters: 450
               ) {
                value.nearbyStation = true
                value.nearbyStationName = station.stationName
                value.matchesRailRoute = true
            }
            if context.isOnRoad {
                var evidence = value.behaviorEvidence ?? []
                if !evidence.contains("Apple 지도 도로 인접") {
                    evidence.append("Apple 지도 도로 인접")
                }
                value.behaviorEvidence = evidence
            }
            return value
        }
        return deterministicStationJourneyEnrichment(enriched)
    }

    private func applyingUserTransitLocations(
        _ reading: SensorReading,
        locations: [UserTransitLocation]
    ) -> SensorReading {
        guard let point = reading.point,
              let location = locations.first(where: {
                  distanceMeters(point, $0.point) <= 100
              }) else {
            return reading
        }
        var value = reading
        value.nearbyStation = true
        value.nearbyStationName = location.name
        switch location.kind {
        case .subwayStation:
            value.matchesRailRoute = true
            value.matchesPublicTransitRoute = true
        case .busStop:
            value.matchesPublicTransitRoute = true
        case .trainStation:
            break
        case .airport:
            value.nearAirport = true
        case .harbor:
            value.nearPort = true
        }
        var evidence = value.behaviorEvidence ?? []
        let marker = "사용자 등록 (\(location.kind.title)): \(location.name)"
        if !evidence.contains(marker) { evidence.append(marker) }
        value.behaviorEvidence = evidence
        return value
    }

    /// Apple의 일시적인 교통 컨텍스트에 의존하지 않고, 보관된 좌표에서
    /// 역 체류(5분)와 역 이탈(50m 이상 2회)을 먼저 확인한 뒤에만 철도
    /// 컨텍스트를 저장한다. 두 도로 끝점만 있는 기록은 이 단계에서
    /// 승격되지 않는다.
    private func deterministicStationJourneyEnrichment(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        guard let journey = SubwayStationCatalog.stationJourney(
            from: readings
        ), journey.isConfirmed else {
            return readings
        }
        let journeyStops = journey.stays.compactMap { stay in
            journey.route.stops.first {
                $0.stationName.compare(
                    stay.stationName,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: .current
                ) == .orderedSame
            }
        }
        return readings.map { reading in
            guard let point = reading.point,
                  let stop = journeyStops.min(by: {
                      guard let lhs = $0.coordinate,
                            let rhs = $1.coordinate else { return false }
                      return distanceMeters(point, lhs)
                          < distanceMeters(point, rhs)
                  }),
                  let coordinate = stop.coordinate,
                  distanceMeters(point, coordinate) <= 450 else {
                return reading
            }
            var value = reading
            value.nearbyStation = true
            value.nearbyStationName = stop.stationName
            value.matchesRailRoute = true
            var evidence = value.behaviorEvidence ?? []
            if !evidence.contains("역 체류·50m 이탈 경로 보강") {
                evidence.append("역 체류·50m 이탈 경로 보강")
            }
            value.behaviorEvidence = evidence
            return value
        }
    }

    private func refiningStaticStation(_ reading: SensorReading) -> SensorReading {
        guard let point = reading.point,
              let station = SubwayStationCatalog.nearest(
                  to: point,
                  maximumDistanceMeters: Self.stationMatchRadiusMeters
              ) else { return reading }
        guard reading.motion != .stationary
            || (reading.speedMetersPerSecond ?? 0) >= 1
            || !reading.gpsAvailable
            || reading.nearbyStation else { return reading }
        var value = reading
        value.nearbyStation = true
        value.nearbyStationName = station.stationName
        return value
    }

    private func context(at point: GeoPoint) async -> AppleTransportContext {
        let key = cacheKey(point)
        if let cached = cache[key],
           Date.now.timeIntervalSince(cached.storedAt) < 6 * 60 * 60 {
            return cached.context
        }

        async let subway = nearbyName(
            query: "지하철역",
            point: point,
            radius: Self.stationMatchRadiusMeters
        )
        async let bus = nearbyName(
            query: "버스정류장",
            point: point,
            radius: AppleTransportContext.busStopMatchRadiusMeters
        )
        async let road = isOnRoad(point)
        let value = await AppleTransportContext(
            subwayStationName: subway,
            busStopName: bus,
            isOnRoad: road
        )
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = CacheEntry(context: value, storedAt: .now)
        return value
    }

    private func nearbyName(
        query: String,
        point: GeoPoint,
        radius: Double
    ) async -> String? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            latitudinalMeters: max(300, radius * 2),
            longitudinalMeters: max(300, radius * 2)
        )
        guard let response = try? await MKLocalSearch(request: request).start()
        else { return nil }
        let origin = CLLocation(
            latitude: point.latitude,
            longitude: point.longitude
        )
        return response.mapItems
            .compactMap { item -> (Double, String)? in
                let distance = origin.distance(from: CLLocation(
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude
                ))
                guard distance <= radius else { return nil }
                return (distance, item.name ?? item.placemark.name ?? query)
            }
            .min(by: { $0.0 < $1.0 })?.1
    }

    private func isOnRoad(_ point: GeoPoint) async -> Bool {
        let location = CLLocation(
            latitude: point.latitude,
            longitude: point.longitude
        )
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location)
            .first
        return placemark?.thoroughfare != nil
            || placemark?.subThoroughfare != nil
    }

    private func sampledIndices(
        _ indices: [Int],
        maximumCount: Int
    ) -> [Int] {
        guard indices.count > maximumCount else { return indices }
        return (0..<maximumCount).map { offset in
            indices[offset * (indices.count - 1) / (maximumCount - 1)]
        }
    }

    private func cacheKey(_ point: GeoPoint) -> String {
        "\(Int((point.latitude * 1_000).rounded())):"
            + "\(Int((point.longitude * 1_000).rounded()))"
    }
}

private final class AppleTransitBoardingSearchHandle: @unchecked Sendable {
    let search: MKLocalSearch

    init(_ search: MKLocalSearch) {
        self.search = search
    }
}

@MainActor
final class AppleTransitBoardingPOIResolver {
    static let shared = AppleTransitBoardingPOIResolver()

    private struct CacheEntry {
        let place: TransitBoardingPlace?
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    func resolving(
        readings: [SensorReading]
    ) async -> [TransitBoardingPlace] {
        let points = sampledPoints(from: readings)
        guard !points.isEmpty else { return [] }

        var places: [TransitBoardingPlace] = []
        for point in points {
            guard !Task.isCancelled else { return [] }
            for kind in UserTransitLocationKind.allCases {
                for query in kind.mapKitQueries {
                    guard !Task.isCancelled else { return [] }
                    let place = await nearbyPlace(
                        query: query,
                        kind: kind,
                        point: point
                    )
                    guard !Task.isCancelled else { return [] }
                    if let place {
                        places.append(place)
                        break
                    }
                }
            }
        }

        var unique: [String: TransitBoardingPlace] = [:]
        for place in places {
            unique[place.id] = place
        }
        return unique.values.sorted {
            if $0.kind == $1.kind { return $0.name < $1.name }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func nearbyPlace(
        query: String,
        kind: UserTransitLocationKind,
        point: GeoPoint
    ) async -> TransitBoardingPlace? {
        let key = "\(kind.rawValue):\(query):"
            + "\(Int((point.latitude * 1_000).rounded())):"
            + "\(Int((point.longitude * 1_000).rounded()))"
        if let cached = cache[key],
           Date.now.timeIntervalSince(cached.storedAt) < 6 * 60 * 60 {
            return cached.place
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            latitudinalMeters: max(300, kind.mapKitSearchRadiusMeters * 2),
            longitudinalMeters: max(300, kind.mapKitSearchRadiusMeters * 2)
        )
        let handle = AppleTransitBoardingSearchHandle(
            MKLocalSearch(request: request)
        )
        let response = await withTaskCancellationHandler(
            operation: { try? await handle.search.start() },
            onCancel: { handle.search.cancel() }
        )
        guard !Task.isCancelled else { return nil }
        let origin = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let place = response?.mapItems
            .compactMap { item -> (Double, TransitBoardingPlace)? in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate),
                      let name = item.name ?? item.placemark.name,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                let distance = origin.distance(
                    from: CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
                guard distance <= kind.mapKitSearchRadiusMeters else {
                    return nil
                }
                let place = TransitBoardingPlace(
                    mapKitIdentifier: item.identifier?.rawValue,
                    mapKitName: name,
                    kind: kind,
                    point: GeoPoint(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        altitude: 0,
                        horizontalAccuracy: 0,
                        verticalAccuracy: 0
                    )
                )
                return (distance, place)
            }
            .min(by: { $0.0 < $1.0 })?.1
        cache[key] = CacheEntry(place: place, storedAt: .now)
        if cache.count > 512 {
            cache.removeAll(keepingCapacity: true)
        }
        return place
    }

    private func sampledPoints(from readings: [SensorReading]) -> [GeoPoint] {
        let valid = readings
            .filter { $0.gpsAvailable && $0.locationFixQuality != .approximate }
            .compactMap(\.point)
            .filter {
                $0.latitude.isFinite && $0.longitude.isFinite
                    && (-90...90).contains($0.latitude)
                    && (-180...180).contains($0.longitude)
            }
            .sorted { lhs, rhs in
                lhs.latitude == rhs.latitude
                    ? lhs.longitude < rhs.longitude
                    : lhs.latitude < rhs.latitude
            }
        guard !valid.isEmpty else { return [] }

        var unique: [GeoPoint] = []
        var keys = Set<String>()
        for point in valid {
            let key = "\(Int((point.latitude * 1_000).rounded())):\(Int((point.longitude * 1_000).rounded()))"
            if keys.insert(key).inserted { unique.append(point) }
        }
        guard unique.count > 4 else { return unique }
        return (0..<4).map { index in
            unique[index * (unique.count - 1) / 3]
        }
    }
}
