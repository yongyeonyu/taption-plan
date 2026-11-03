import Foundation
import TaptionPlanEngine

/// Display-only position projection for live map updates. It interpolates
/// between adjacent valid fixes and falls back to a catalog station anchor
/// when GPS is unavailable; no sensor record is rewritten.
struct RealtimeSensorMapProjection: Hashable, Sendable {
    private static let maximumInterpolationGap: TimeInterval = 20 * 60
    private static let maximumFallbackAge: TimeInterval = 5 * 60
    private static let maximumTemporaryLocationAge: TimeInterval = 30 * 60

    let timestamp: Date
    let point: GeoPoint
    let isEstimated: Bool
    let source: String

    static func project(
        readings: [SensorReading],
        at timestamp: Date,
        temporaryLocations: [SubwayStationCatalog.TemporaryLocation] = []
    ) -> Self? {
        guard RouteTimelineTimestamp.isValid(timestamp) else { return nil }
        let ordered = readings.filter { reading in
            guard RouteTimelineTimestamp.isValid(reading.timestamp),
                  reading.gpsAvailable,
                  reading.locationFixQuality != .approximate,
                  let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= 150 else {
                return false
            }
            return true
        }.sorted { $0.timestamp < $1.timestamp }
        if let exact = ordered.first(where: { $0.timestamp == timestamp }), let point = exact.point {
            return Self(timestamp: timestamp, point: point, isEstimated: false, source: "GPS")
        }
        if let before = ordered.last(where: { $0.timestamp <= timestamp }),
           let after = ordered.first(where: { $0.timestamp >= timestamp }),
           let start = before.point, let end = after.point {
            let duration = after.timestamp.timeIntervalSince(before.timestamp)
            if duration <= maximumInterpolationGap {
                let fraction = duration > 0
                    ? min(1, max(0, timestamp.timeIntervalSince(before.timestamp) / duration))
                    : 0
                return Self(
                    timestamp: timestamp,
                    point: interpolate(start, end, fraction: fraction),
                    isEstimated: true,
                    source: "GPS 보간"
                )
            }
        }
        if let fallback = temporaryLocations.filter({
            RouteTimelineTimestamp.isValid($0.timestamp)
        }).min(by: {
            abs($0.timestamp.timeIntervalSince(timestamp))
                < abs($1.timestamp.timeIntervalSince(timestamp))
        }), abs(fallback.timestamp.timeIntervalSince(timestamp))
            <= maximumTemporaryLocationAge {
            return Self(timestamp: timestamp, point: fallback.point, isEstimated: true, source: fallback.reason)
        }
        return ordered.last(where: {
            abs(timestamp.timeIntervalSince($0.timestamp)) <= maximumFallbackAge
        }).flatMap { reading in
            reading.point.map { Self(timestamp: timestamp, point: $0, isEstimated: true, source: "최근 GPS") }
        }
    }

    private static func interpolate(_ start: GeoPoint, _ end: GeoPoint, fraction: Double) -> GeoPoint {
        let f = min(1, max(0, fraction))
        return GeoPoint(
            latitude: start.latitude + (end.latitude - start.latitude) * f,
            longitude: RouteTimelineLongitude.interpolate(
                from: start.longitude,
                to: end.longitude,
                fraction: f
            ),
            altitude: start.altitude + (end.altitude - start.altitude) * f,
            horizontalAccuracy: max(start.horizontalAccuracy, end.horizontalAccuracy),
            verticalAccuracy: max(start.verticalAccuracy, end.verticalAccuracy)
        )
    }
}
