import Foundation
import TaptionPlanEngine

/// HealthKit 운동 경로 표본을 기기 표본과 합친다. 우리 앱이 이미 같은 시각의
/// 위치를 남겼다면 중복이므로 버리고, 비어 있는 구간만 채운다.
enum HealthRouteMergeEngine {
    static let minimumSpacingSeconds: TimeInterval = 20

    static func merging(
        _ routeReadings: [SensorReading],
        into existing: [SensorReading]
    ) -> [SensorReading] {
        let validRouteReadings = routeReadings.filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
        }
        guard !validRouteReadings.isEmpty else { return [] }
        let existingTimes = existing
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.point != nil
            }
            .map(\.timestamp)
            .sorted()
        var accepted: [Date] = []
        var result: [SensorReading] = []
        for reading in validRouteReadings.sorted(by: {
            $0.timestamp < $1.timestamp
        }) {
            guard !hasNeighbor(reading.timestamp, in: existingTimes),
                  !hasNeighbor(reading.timestamp, in: accepted) else {
                continue
            }
            accepted.append(reading.timestamp)
            result.append(reading)
        }
        guard !result.isEmpty, !existingTimes.isEmpty else { return result }
        // Separate streams can each look plausible while disagreeing with
        // the device's fixes around a gap. Validate their combined timeline.
        let retainedIDs = Set(TaptionRouteEngineAdapter.filteredReadings(
            from: existing + result,
            includeLowConfidenceBoundaries: false
        ).map(\.id))
        return result.filter { retainedIDs.contains($0.id) }
    }

    private static func hasNeighbor(
        _ date: Date,
        in sorted: [Date]
    ) -> Bool {
        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sorted[middle] < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower < sorted.count,
           abs(sorted[lower].timeIntervalSince(date)) < minimumSpacingSeconds {
            return true
        }
        return lower > 0
            && abs(sorted[lower - 1].timeIntervalSince(date))
                < minimumSpacingSeconds
    }
}
