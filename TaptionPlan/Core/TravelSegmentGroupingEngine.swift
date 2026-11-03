import Foundation
import TaptionPlanEngine

enum TravelSegmentGroupingEngine {
    static let defaultMaximumGap: TimeInterval = 5 * 60

    static func groups(
        from segments: [TravelSegment],
        maximumGap: TimeInterval = defaultMaximumGap
    ) -> [TravelSegmentGroup] {
        let ordered = segments.sorted { $0.span.start < $1.span.start }
        var grouped: [[TravelSegment]] = []

        for segment in ordered {
            guard var current = grouped.popLast() else {
                grouped.append([segment])
                continue
            }
            if canMerge(
                segment,
                after: current.last,
                maximumGap: maximumGap
            ) {
                current.append(segment)
                grouped.append(current)
            } else {
                grouped.append(current)
                grouped.append([segment])
            }
        }

        return grouped.map(TravelSegmentGroup.init)
    }

    private static func canMerge(
        _ next: TravelSegment,
        after previous: TravelSegment?,
        maximumGap: TimeInterval
    ) -> Bool {
        guard let previous,
              previous.mode == next.mode else {
            return false
        }
        let gap = next.span.start.timeIntervalSince(previous.span.end)
        guard gap <= maximumGap else { return false }
        if let previousDestination = previous.toPlaceID,
           let nextOrigin = next.fromPlaceID,
           previousDestination != nextOrigin {
            return false
        }
        return true
    }
}

extension TimeSpan {
    /// 짧은 쪽의 절반 이상이 겹치면 같은 구간으로 본다.
    func overlapsMostly(_ other: TimeSpan) -> Bool {
        guard let overlap = intersection(with: other) else { return false }
        return overlap.duration >= min(duration, other.duration) * 0.5
    }
}
