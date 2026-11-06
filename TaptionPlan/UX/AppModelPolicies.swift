import Foundation
import TaptionPlanCore

/// The WBS store loads one normalized immutable workspace and derives the
/// visible presentation from that snapshot. Plan follows the same boundary
/// for a map day: persisted iPhone/Watch data is read once, then day-scoped
/// arrays are derived without changing the source snapshot or raw readings.

enum MapCurrentLocationAnchorPolicy {
    static let maximumAge: TimeInterval = 5 * 60
    static let maximumPreciseAccuracy =
        TrackingSessionPolicy.activeHorizontalAccuracyLimit

    static func latestValidReading(
        in readings: [SensorReading],
        now: Date = .now
    ) -> SensorReading? {
        let valid = readings.filter { isValid($0, now: now) }
        return valid
            .filter(isPrecise)
            .max { $0.timestamp < $1.timestamp }
            ?? valid
                .filter { $0.locationFixQuality == .approximate }
                .max { $0.timestamp < $1.timestamp }
    }

    private static func isValid(
        _ reading: SensorReading,
        now: Date
    ) -> Bool {
        guard let point = reading.point,
              reading.timestamp <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(reading.timestamp) <= maximumAge else {
            return false
        }
        return (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy >= 0
            && (isPrecise(reading) || reading.locationFixQuality == .approximate)
    }

    private static func isPrecise(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable || reading.locationFixQuality == .precise,
              let point = reading.point else { return false }
        return point.horizontalAccuracy <= maximumPreciseAccuracy
    }
}

enum BackgroundLocationCollectionPolicy {
    static func isEnabled(hasAlwaysAuthorization: Bool) -> Bool {
        hasAlwaysAuthorization
    }
}

enum ConfirmedSleepSpanEditor {
    static func replacing(
        _ existing: [TimeSpan],
        removing: [TimeSpan] = [],
        adding: [TimeSpan] = []
    ) -> [TimeSpan] {
        let cuts = normalized(removing)
        let remaining = normalized(existing).flatMap {
            ActualIntervalMergeEngine.subtracting(cuts, from: $0)
        }
        return normalized(remaining + adding)
    }

    private static func normalized(_ spans: [TimeSpan]) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var result: [TimeSpan] = []
        for span in ordered {
            guard let previous = result.last,
                  span.start <= previous.end else {
                result.append(span)
                continue
            }
            result[result.count - 1] = TimeSpan(
                start: previous.start,
                end: max(previous.end, span.end)
            )
        }
        return result
    }
}
