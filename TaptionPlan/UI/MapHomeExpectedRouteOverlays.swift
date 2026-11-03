import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeForecastRouteDisplayPolicy {
    static let maximumVisibleRoutes = 8
}

struct MapHomeExpectedRouteOverlay: Identifiable {
    let id: UUID
    let segmentID: UUID
    let mode: TravelMode
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]
    let segmentLengths: [Double]
    let geometrySignature: Int

    init(
        id: UUID,
        segmentID: UUID,
        mode: TravelMode,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.segmentID = segmentID
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        segmentLengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(
            for: coordinates
        )
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }

    private init(
        id: UUID,
        segmentID: UUID,
        mode: TravelMode,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double],
        geometrySignature: Int
    ) {
        self.id = id
        self.segmentID = segmentID
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        self.segmentLengths = segmentLengths
        self.geometrySignature = geometrySignature
    }

    func coordinate(at date: Date) -> CLLocationCoordinate2D? {
        MapHomeExpectedRoutePlaybackMath.coordinate(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: coordinates,
            segmentLengths: segmentLengths
        )
    }

    func visible(through cutoff: Date) -> Self? {
        guard cutoff > departureDate, coordinates.count >= 2 else { return nil }
        guard cutoff < arrivalDate else { return self }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        guard duration > 0 else { return self }
        let fraction = min(
            max(cutoff.timeIntervalSince(departureDate) / duration, 0),
            1
        )
        let visible = Self.prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: segmentLengths
        )
        return Self(
            id: id,
            segmentID: segmentID,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: visible.coordinates,
            segmentLengths: visible.segmentLengths,
            geometrySignature: MapHomeRouteGeometrySignature.derived(
                from: geometrySignature,
                coordinates: visible.coordinates
            )
        )
    }

    static func prefixByDistance(
        _ coordinates: [CLLocationCoordinate2D],
        fraction: Double,
        segmentLengths cachedLengths: [Double]? = nil
    ) -> [CLLocationCoordinate2D] {
        prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: cachedLengths
        ).coordinates
    }

    struct PrefixResult {
        let coordinates: [CLLocationCoordinate2D]
        let segmentLengths: [Double]
    }

    static func prefixByDistanceResult(
        _ coordinates: [CLLocationCoordinate2D],
        fraction: Double,
        segmentLengths cachedLengths: [Double]? = nil
    ) -> PrefixResult {
        guard coordinates.count >= 2 else {
            return PrefixResult(coordinates: coordinates, segmentLengths: [])
        }
        let lengths = cachedLengths?.count == coordinates.count - 1
            ? cachedLengths!
            : MapHomeExpectedRoutePlaybackMath.segmentLengths(for: coordinates)
        let total = lengths.reduce(0, +)
        guard total > 0 else {
            return PrefixResult(
                coordinates: Array(coordinates.prefix(2)),
                segmentLengths: [0]
            )
        }

        let target = total * min(max(fraction, 0), 1)
        var traversed = 0.0
        var result = [coordinates[0]]
        var resultLengths: [Double] = []
        for (index, length) in lengths.enumerated() {
            let next = coordinates[index + 1]
            guard length > 0 else { continue }
            if traversed + length >= target {
                let ratio = min(
                    max((target - traversed) / length, 0),
                    1
                )
                result.append(
                    CLLocationCoordinate2D(
                        latitude: coordinates[index].latitude
                            + (next.latitude - coordinates[index].latitude) * ratio,
                        longitude: RouteTimelineLongitude.interpolate(
                            from: coordinates[index].longitude,
                            to: next.longitude,
                            fraction: ratio
                        )
                    )
                )
                resultLengths.append(length * ratio)
                return PrefixResult(
                    coordinates: result.count >= 2
                        ? result
                        : Array(coordinates.prefix(2)),
                    segmentLengths: result.count >= 2
                        ? resultLengths
                        : [length]
                )
            }
            result.append(next)
            resultLengths.append(length)
            traversed += length
        }
        return PrefixResult(
            coordinates: coordinates,
            segmentLengths: lengths
        )
    }
}

struct MapHomeWBSGeneratedRouteOverlay: Identifiable {
    let id: String
    let mode: TravelMode?
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]
    let segmentLengths: [Double]
    let geometrySignature: Int

    init(
        id: String,
        mode: TravelMode?,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        segmentLengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(
            for: coordinates
        )
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }

    private init(
        id: String,
        mode: TravelMode?,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double],
        geometrySignature: Int
    ) {
        self.id = id
        self.mode = mode
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.coordinates = coordinates
        self.segmentLengths = segmentLengths
        self.geometrySignature = geometrySignature
    }

    func visible(through cutoff: Date) -> Self? {
        guard cutoff > departureDate, coordinates.count >= 2 else { return nil }
        guard cutoff < arrivalDate else { return self }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        guard duration > 0 else { return self }
        let fraction = min(
            max(cutoff.timeIntervalSince(departureDate) / duration, 0),
            1
        )
        let visible = MapHomeExpectedRouteOverlay.prefixByDistanceResult(
            coordinates,
            fraction: fraction,
            segmentLengths: segmentLengths
        )
        return Self(
            id: id,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: visible.coordinates,
            segmentLengths: visible.segmentLengths,
            geometrySignature: MapHomeRouteGeometrySignature.derived(
                from: geometrySignature,
                coordinates: visible.coordinates
            )
        )
    }
}

struct MapHomeExpectedRouteRequestBatch: Sendable {
    let overlayRequests: [ExpectedRouteRequest]
    let playbackRequests: [ExpectedRouteRequest]
    let overlayOperationCount: Int
    let playbackOperationCount: Int
    let readingsWithPointCount: Int
    let unconfirmedTravelCount: Int
}

struct MapHomeExpectedRouteInputKey: Equatable, Sendable {
    let selectedDay: Date
    let dayEnd: Date
    let dayProjectionRevision: UInt64
    let daySourceRevision: UInt64?
    let daySourceUpdatedAt: Date?
    let daySourceFingerprint: String?
    let isPreview: Bool
    let readingsPreparationID: UUID
    let normalizedReadings: MapHomeDayCacheReadingsFingerprint
    let normalizedLastRouteInputSignature: String
    let liveReadings: MapHomeDayCacheReadingsFingerprint
    let liveLastUpdatedAt: Date?
    let liveLastRouteInputSignature: String
    let latestRouteInputSignature: String
}

struct MapHomeForecastRouteState {
    let expected: [MapHomeExpectedRouteOverlay]
    let generated: [MapHomeWBSGeneratedRouteOverlay]
    let refreshGeneration: UInt64
    let inputKey: MapHomeExpectedRouteInputKey
}

struct MapHomeSubwayRouteOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let estimated: Bool
    let geometrySignature: Int
    let travelID: UUID?

    init(
        id: UUID,
        coordinates: [CLLocationCoordinate2D],
        estimated: Bool,
        travelID: UUID? = nil
    ) {
        self.id = id
        self.coordinates = coordinates
        self.estimated = estimated
        self.travelID = travelID
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }
}

final class MapHomeSubwayRouteCache {
    private var day: Date?
    private var minute: Int?
    private var revision: UInt64?
    private var overlays: [MapHomeSubwayRouteOverlay] = []

    func invalidate() {
        minute = nil
        revision = nil
    }

    func restore(day: Date, overlays: [MapHomeSubwayRouteOverlay]) {
        self.day = day
        self.overlays = overlays
        invalidate()
    }

    func routes(day: Date, minute: Int, sourceRevision: UInt64?,
                make: () -> [MapHomeSubwayRouteOverlay]) -> [MapHomeSubwayRouteOverlay] {
        // Camera redraws can arrive before the next immutable day snapshot is ready.
        // Missing input is not an authoritative empty route list.
        guard let sourceRevision else { return self.day == day ? overlays : [] }
        if self.day != day || self.minute != minute || revision != sourceRevision {
            overlays = make()
            self.day = day
            self.minute = minute
            revision = sourceRevision
        }
        return overlays
    }
}

enum MapHomeSubwayRouteOverlayEngine {
    static func overlays(
        travel: [TravelSegment],
        readings: [SensorReading],
        day: TimeSpan,
        through cutoff: Date
    ) -> [MapHomeSubwayRouteOverlay] {
        guard cutoff > day.start else { return [] }
        let observedReadings = readings.filter {
            $0.timestamp >= day.start && $0.timestamp < day.end && $0.timestamp <= cutoff
        }
        let readingIndex = SensorEvidenceTimeIndex(readings: observedReadings)
        let subwaySegments = travel
            .filter {
                RouteConfirmedSubwayIntervalIndex.hasTrustedSubwayRoute($0)
                    && $0.span.start <= cutoff
                    && $0.span.intersection(with: day) != nil
            }
            .sorted { $0.span.start < $1.span.start }
        let resolvedSubwaySegments = subwaySegments.compactMap {
            SubwayTravelSegmentEngine.confirmedRoute(for: $0, readingIndex: readingIndex)
        }
        // 자동 판정 지하철은 GPS가 끊긴 구간에만 예상 경로를 그린다. 나머지는 실제 경로가 있다(PLB1103A01).
        let automatic = resolvedSubwaySegments.filter { !$0.isConfirmed }.flatMap { resolved in
            MapHomePlaybackLocation.subwayGapRoutes(segment: resolved, readings: observedReadings, through: cutoff)
                .enumerated().compactMap { index, points -> MapHomeSubwayRouteOverlay? in
                    var id = resolved.id.uuid
                    id.15 = id.15 &+ UInt8(truncatingIfNeeded: index + 1)
                    return makeOverlay(id: UUID(uuid: id), points: points, estimated: false, travelID: resolved.id)
                }
        }
        let confirmed = automatic + resolvedSubwaySegments.filter(\.isConfirmed).compactMap {
            resolved -> MapHomeSubwayRouteOverlay? in
            let prefix = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                for: resolved,
                through: cutoff
            )
            let points: [GeoPoint]
            if resolved.span.start < day.start,
               let dayStartPoint = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                   for: resolved, through: day.start).last {
                let oldCount = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                    for: resolved, through: day.start).count
                points = [dayStartPoint] + prefix.dropFirst(max(0, oldCount - 1))
            } else {
                points = prefix
            }
            return makeOverlay(
                id: resolved.id,
                points: points,
                estimated: false,
                travelID: resolved.id
            )
        }

        let railCandidates = travel
            .filter {
                ($0.mode == .train || ($0.mode == .subway && $0.isConfirmed
                    && $0.subwayRoute.map(SubwayStationCatalog.isValid) != true))
                    // 다른 날 기억으로만 지하철이 된 구간에는 추정 노선을 그리지 않는다(PAW1102A03).
                    && !ActivityClassificationLockEngine.isRememberedOnlySubway($0)
                    && $0.span.start <= cutoff
                    && $0.span.intersection(with: day) != nil
            }
            .sorted { $0.span.start < $1.span.start }
        guard !railCandidates.isEmpty else { return confirmed }

        let inferredSubway = SubwayTravelSegmentEngine.segments(
            from: observedReadings,
            within: railCandidates.map(\.span)
        )
        var seenRoutes = Set(resolvedSubwaySegments.compactMap(\.subwayRoute))
        let estimated = railCandidates.compactMap { candidate -> MapHomeSubwayRouteOverlay? in
            // A short confirmed fragment must not hide the rest of an observed rail journey.
            guard let inferred = inferredSubway
                    .filter({ hasSubstantialOverlap($0.span, candidate.span) })
                    .max(by: { $0.span.duration < $1.span.duration }),
                  let route = inferred.subwayRoute,
                  SubwayStationCatalog.isValid(route),
                  seenRoutes.insert(route).inserted else {
                return nil
            }
            return makeOverlay(
                id: confirmed.contains(where: { $0.id == candidate.id }) ? inferred.id : candidate.id,
                points: route.coordinates,
                estimated: true,
                travelID: candidate.id
            )
        }
        return confirmed + estimated
    }

    private static func hasSubstantialOverlap(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Bool {
        guard let overlap = lhs.intersection(with: rhs) else { return false }
        let shorter = max(1, min(lhs.duration, rhs.duration))
        return overlap.duration / shorter >= 0.5
    }

    private static func makeOverlay(
        id: UUID,
        points: [GeoPoint],
        estimated: Bool,
        travelID: UUID
    ) -> MapHomeSubwayRouteOverlay? {
        let coordinates = points.compactMap { point -> CLLocationCoordinate2D? in
            guard isValid(point) else { return nil }
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
        guard coordinates.count >= 2 else { return nil }
        return MapHomeSubwayRouteOverlay(
            id: id,
            coordinates: coordinates,
            estimated: estimated,
            travelID: travelID
        )
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}
