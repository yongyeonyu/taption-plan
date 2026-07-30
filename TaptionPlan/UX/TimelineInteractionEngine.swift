import Foundation

enum TimeSliderHandle: Sendable {
    case start
    case body
    case end
}

enum TimeSliderEngine {
    static func snapInterval(
        velocityPointsPerSecond: Double,
        isLongPressPrecision: Bool
    ) -> TimeInterval {
        if isLongPressPrecision { return 60 }
        return abs(velocityPointsPerSecond) >= 650 ? 600 : 60
    }

    static func adjust(
        _ span: TimeSpan,
        handle: TimeSliderHandle,
        delta: TimeInterval,
        velocityPointsPerSecond: Double,
        isLongPressPrecision: Bool,
        bounds: TimeSpan? = nil,
        minimumDuration: TimeInterval = 60
    ) -> TimeSpan {
        let step = snapInterval(
            velocityPointsPerSecond: velocityPointsPerSecond,
            isLongPressPrecision: isLongPressPrecision
        )
        let snappedDelta = (delta / step).rounded() * step
        var start = span.start
        var end = span.end

        switch handle {
        case .start:
            start = min(
                start.addingTimeInterval(snappedDelta),
                end.addingTimeInterval(-minimumDuration)
            )
        case .body:
            start = start.addingTimeInterval(snappedDelta)
            end = end.addingTimeInterval(snappedDelta)
        case .end:
            end = max(
                end.addingTimeInterval(snappedDelta),
                start.addingTimeInterval(minimumDuration)
            )
        }

        if let bounds {
            if start < bounds.start {
                let correction = bounds.start.timeIntervalSince(start)
                start = start.addingTimeInterval(correction)
                if handle == .body {
                    end = end.addingTimeInterval(correction)
                }
            }
            if end > bounds.end {
                let correction = bounds.end.timeIntervalSince(end)
                end = end.addingTimeInterval(correction)
                if handle == .body {
                    start = start.addingTimeInterval(correction)
                }
            }
        }
        return TimeSpan(start: start, end: end)
    }

    static func crossedTenMinuteTick(
        previous: Date,
        current: Date
    ) -> Bool {
        Int(previous.timeIntervalSince1970 / 600)
            != Int(current.timeIntervalSince1970 / 600)
    }
}
