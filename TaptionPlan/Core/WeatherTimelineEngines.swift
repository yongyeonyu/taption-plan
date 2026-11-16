import Foundation
import TaptionPlanCore

/// 지난 날의 날씨를 그 시각의 GPS 위치 기준으로 고정한다(WTH1020C01). 미래는 현재 위치 예보, 과거는 GPS 위치의 실제 날씨.
/// 하루를 시(hour)로 나눠 각 시의 위치(가운데 시각에 가장 가까운 GPS, 없으면 집)를 정하고, 가까운 연속한 시를 한 묶음으로
/// 묶어(날씨 호출 수를 줄인다) 묶음마다 시간별 날씨를 받아 해당 시의 기존 날씨를 교체한다.
enum WeatherDayFixEngine {
    struct HourLocation: Equatable {
        var hourStart: Date
        var hourEnd: Date
        var point: GeoPoint
    }

    struct Group: Equatable {
        var point: GeoPoint
        var start: Date
        var end: Date
        var hours: [HourLocation]
    }

    /// 같은 묶음으로 보는 최대 거리(첫 시의 위치 기준).
    static let groupRadiusMeters = 1_000.0
    /// 이보다 부정확한 위치 점은 날씨 위치로 쓰지 않는다.
    static let maximumAccuracyMeters = 1_000.0

    static func hourLocations(
        dayStart: Date,
        dayEnd: Date,
        readings: [SensorReading],
        home: GeoPoint?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HourLocation] {
        let located = readings
            .filter {
                guard let point = $0.point else { return false }
                return point.horizontalAccuracy >= 0
                    && point.horizontalAccuracy <= maximumAccuracyMeters
                    && $0.timestamp >= dayStart && $0.timestamp < dayEnd
            }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [HourLocation] = []
        var cursor = dayStart
        var index = 0
        while cursor < dayEnd,
              let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next > cursor {
            let middle = cursor.addingTimeInterval(next.timeIntervalSince(cursor) / 2)
            while index + 1 < located.count,
                  abs(located[index + 1].timestamp.timeIntervalSince(middle))
                    <= abs(located[index].timestamp.timeIntervalSince(middle)) {
                index += 1
            }
            if let reading = located.isEmpty ? nil : located[index], let point = reading.point {
                result.append(HourLocation(hourStart: cursor, hourEnd: next, point: point))
            } else if let home {
                result.append(HourLocation(hourStart: cursor, hourEnd: next, point: home))
            }
            cursor = next
        }
        return result
    }

    static func groups(_ hours: [HourLocation]) -> [Group] {
        var result: [Group] = []
        for hour in hours {
            if var last = result.last,
               last.hours.last?.hourEnd == hour.hourStart,
               distanceMeters(last.point, hour.point) <= groupRadiusMeters {
                last.end = hour.hourEnd
                last.hours.append(hour)
                result[result.count - 1] = last
            } else {
                result.append(Group(point: hour.point, start: hour.hourStart, end: hour.hourEnd, hours: [hour]))
            }
        }
        return result
    }

    /// 고정한 시의 기존 날씨(예보·관측 모두)를 빼고 고정 값을 넣는다. 받지 못한 시의 기존 값은 그대로 둔다.
    static func replacing(
        _ existing: [WeatherContext],
        withFixed fixed: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [WeatherContext] {
        let fixedBuckets = Set(fixed.map { WeatherTimelineEngine.hourBucket(for: $0.observedAt, calendar: calendar) })
        let kept = existing.filter {
            !fixedBuckets.contains(WeatherTimelineEngine.hourBucket(for: $0.observedAt, calendar: calendar))
        }
        return (kept + fixed).sorted { $0.observedAt < $1.observedAt }
    }
}

enum WeatherTimelineEngine {
    static let defaultDuration: TimeInterval = 15 * 60

    private struct Signature: Equatable {
        let condition: String
        let symbolName: String
        let temperature: Int
        let airGrade: AirQualityGrade?
        let location: LocationSignature
    }

    private struct LocationSignature: Equatable {
        let placeID: UUID?
        let latitude: Int?
        let longitude: Int?

        init(_ context: WeatherContext) {
            placeID = context.placeID
            guard context.placeID == nil, let point = context.point else {
                latitude = nil
                longitude = nil
                return
            }
            latitude = Int((point.latitude * 1_000).rounded())
            longitude = Int((point.longitude * 1_000).rounded())
        }
    }

    /// Returns the local-clock hour used as the stable replacement key for a
    /// weather observation and its forecast.
    static func hourBucket(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    /// Replaces only the same location/time projection. Raw weather samples
    /// remain append-only in the device archive; this value is the persisted
    /// display projection.
    static func replacing(
        _ existing: [WeatherContext],
        current: WeatherContext? = nil,
        forecast: [WeatherContext] = [],
        forecastRange: TimeSpan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [WeatherContext] {
        let currentBucket = current.map {
            hourBucket(for: $0.observedAt, calendar: calendar)
        }
        var incomingForecast = deduplicated(
            forecast,
            calendar: calendar
        )
        if let current, let currentBucket {
            incomingForecast.removeAll {
                matches($0, current)
                    && hourBucket(for: $0.observedAt, calendar: calendar)
                        == currentBucket
            }
        }

        let kept = existing.filter { value in
            if let current, let currentBucket,
               matches(value, current),
               hourBucket(for: value.observedAt, calendar: calendar)
                    == currentBucket {
                return false
            }
            if let forecastRange, !incomingForecast.isEmpty,
               value.isForecast == true, value.placeID == nil,
               !(value.observedAt >= forecastRange.start
                    && value.observedAt < forecastRange.end) {
                return false
            }
            guard let forecastRange, !incomingForecast.isEmpty,
                  value.observedAt >= forecastRange.start,
                  value.observedAt < forecastRange.end else {
                return true
            }
            return !incomingForecast.contains {
                matches(value, $0)
                    && hourBucket(for: value.observedAt, calendar: calendar)
                        == hourBucket(
                            for: $0.observedAt,
                            calendar: calendar
                        )
            }
        }

        var result = kept
        if let current {
            result.append(current)
        }
        result.append(contentsOf: incomingForecast)
        return coalesced(result)
    }

    static func span(
        for context: WeatherContext,
        defaultDuration: TimeInterval = 15 * 60
    ) -> TimeSpan {
        let fallbackEnd = context.observedAt.addingTimeInterval(defaultDuration)
        return TimeSpan(
            start: context.observedAt,
            end: max(
                context.observedAt.addingTimeInterval(1),
                context.validUntil ?? fallbackEnd
            )
        )
    }

    static func coalesced(
        _ contexts: [WeatherContext],
        defaultDuration: TimeInterval = 15 * 60
    ) -> [WeatherContext] {
        var seen = Set<UUID>()
        // Open-Meteo's free tier forbids commercial use, so its rows are
        // retired on load and raw replay. The raw envelopes stay untouched.
        let ordered = contexts
            .filter { !$0.isFromRetiredProvider && seen.insert($0.id).inserted }
            .sorted { $0.observedAt < $1.observedAt }
        var result: [WeatherContext] = []
        result.reserveCapacity(ordered.count)

        for original in ordered {
            var current = original
            if current.airQuality?.isFromRetiredProvider == true { current.airQuality = nil }
            current.validUntil = span(
                for: current,
                defaultDuration: defaultDuration
            ).end
            if current.isForecast == true, current.placeID == nil,
               let index = result.lastIndex(where: {
                   $0.isForecast == true && $0.placeID == nil
                       && hourBucket(for: $0.observedAt)
                           == hourBucket(for: current.observedAt)
               }) {
                if (current.fetchedAt ?? .distantPast)
                    >= (result[index].fetchedAt ?? .distantPast) {
                    result[index] = current
                }
                continue
            }
            guard let lastIndex = result.indices.last else {
                result.append(current)
                continue
            }

            let last = result[lastIndex]
            let lastSpan = span(for: last, defaultDuration: defaultDuration)
            if signature(last) == signature(current) {
                result[lastIndex].validUntil = max(
                    lastSpan.end,
                    span(for: current, defaultDuration: defaultDuration).end
                )
                // Keep the most recent detail values while preserving one
                // continuous block for the same displayed weather.
                result[lastIndex].airQuality = current.airQuality
                result[lastIndex].point = current.point ?? result[lastIndex].point
                result[lastIndex].placeID = current.placeID ?? result[lastIndex].placeID
                result[lastIndex].placeName = current.placeName ?? result[lastIndex].placeName
                if let fetchedAt = current.fetchedAt,
                   fetchedAt > (result[lastIndex].fetchedAt ?? .distantPast) {
                    result[lastIndex].fetchedAt = fetchedAt
                    result[lastIndex].isStale = current.isStale
                }
            } else {
                result[lastIndex].validUntil = current.observedAt
                result.append(current)
            }
        }
        return result
    }

    /// Returns only the points where the displayed weather changes. The raw
    /// archive keeps those transition points; the full timeline is rebuilt by
    /// carrying each value forward until the next point.
    static func changedRawContexts(
        _ incoming: [WeatherContext],
        relativeTo existing: [WeatherContext]
    ) -> [WeatherContext] {
        var timeline = existing
        var changes: [WeatherContext] = []
        for context in incoming.sorted(by: {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let previous = timeline
                .filter {
                    sameRawStream($0, context)
                        && $0.observedAt <= context.observedAt
                }
                .max {
                    if $0.observedAt != $1.observedAt {
                        return $0.observedAt < $1.observedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
            guard let previous else {
                changes.append(context)
                timeline.append(context)
                continue
            }
            if rawDisplaySignature(previous) != rawDisplaySignature(context) {
                changes.append(context)
            }
            timeline.append(context)
        }
        return changes
    }

    private static func signature(_ context: WeatherContext) -> Signature {
        Signature(
            condition: context.condition,
            symbolName: context.symbolName,
            temperature: AppRegion.current.temperature(celsius: context.temperatureCelsius),
            // Merge by what the timeline shows.  Raw PM values, provider and
            // fallback state belong to the detail view and must not split a
            // visually identical weather run.
            airGrade: context.airQuality?.overallGrade,
            location: LocationSignature(context)
        )
    }

    private struct RawDisplaySignature: Equatable {
        let symbolName: String
        let temperature: Int
        let airGrade: AirQualityGrade?
        let location: LocationSignature?
    }

    private static func sameRawStream(
        _ lhs: WeatherContext,
        _ rhs: WeatherContext
    ) -> Bool {
        guard (lhs.isForecast == true) == (rhs.isForecast == true) else {
            return false
        }
        guard lhs.placeID == rhs.placeID else { return false }
        if lhs.isForecast == true, lhs.placeID == nil { return true }
        guard lhs.placeID == nil else { return true }
        return LocationSignature(lhs) == LocationSignature(rhs)
    }

    private static func rawDisplaySignature(
        _ context: WeatherContext
    ) -> RawDisplaySignature {
        RawDisplaySignature(
            symbolName: context.symbolName,
            temperature: AppRegion.current.temperature(celsius: context.temperatureCelsius),
            airGrade: context.airQuality?.overallGrade,
            location: context.isForecast == true && context.placeID == nil
                ? nil
                : LocationSignature(context)
        )
    }

    private static func deduplicated(
        _ contexts: [WeatherContext],
        calendar: Calendar
    ) -> [WeatherContext] {
        var result: [WeatherContext] = []
        for context in contexts.sorted(by: { $0.observedAt < $1.observedAt }) {
            let bucket = hourBucket(for: context.observedAt, calendar: calendar)
            if let index = result.lastIndex(where: {
                matches($0, context)
                    && hourBucket(for: $0.observedAt, calendar: calendar)
                        == bucket
            }) {
                let previous = result[index]
                let previousFetchedAt = previous.fetchedAt ?? .distantPast
                let fetchedAt = context.fetchedAt ?? .distantPast
                if fetchedAt >= previousFetchedAt {
                    result[index] = context
                }
            } else {
                result.append(context)
            }
        }
        return result
    }

    private static func matches(
        _ lhs: WeatherContext,
        _ rhs: WeatherContext
    ) -> Bool {
        if lhs.isForecast == true, rhs.isForecast == true,
           lhs.placeID == nil, rhs.placeID == nil {
            return true
        }
        guard lhs.placeID == rhs.placeID else { return false }
        switch (lhs.point, rhs.point) {
        case let (lhsPoint?, rhsPoint?):
            return distanceMeters(lhsPoint, rhsPoint) <= 100
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}
