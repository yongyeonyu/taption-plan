import Foundation

enum GanttZoomStage: Int, CaseIterable, Comparable, Sendable {
    case year
    case month
    case week
    case day
    case hour
    case fifteenMinutes
    case fiveMinutes
    case oneMinute

    static func < (lhs: GanttZoomStage, rhs: GanttZoomStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .year: "년"
        case .month: "월"
        case .week: "주"
        case .day: "일"
        case .hour: "1시간"
        case .fifteenMinutes: "15분"
        case .fiveMinutes: "5분"
        case .oneMinute: "1분"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .year: 366 * 24 * 60 * 60
        case .month: 31 * 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .day: 24 * 60 * 60
        case .hour: 60 * 60
        case .fifteenMinutes: 15 * 60
        case .fiveMinutes: 5 * 60
        case .oneMinute: 60
        }
    }

    var narrower: GanttZoomStage? {
        GanttZoomStage(rawValue: rawValue + 1)
    }

    var broader: GanttZoomStage? {
        GanttZoomStage(rawValue: rawValue - 1)
    }

    static func nearest(to visibleDuration: TimeInterval) -> GanttZoomStage {
        allCases.min {
            abs(log(max(60, visibleDuration) / $0.duration))
                < abs(log(max(60, visibleDuration) / $1.duration))
        } ?? .day
    }
}

enum GanttPrecisionPresentation {
    static func label(
        title: String,
        startsAt: Date?,
        endsAt: Date?,
        detailText: String?,
        visibleDuration: TimeInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard visibleDuration
                <= GanttZoomStage.oneMinute.duration * 1.15,
              let startsAt,
              let endsAt else {
            return title
        }
        let start = timeLabel(startsAt, calendar: calendar)
        let end = timeLabel(endsAt, calendar: calendar)
        if let detailText {
            return "\(start)–\(end) · \(detailText)"
        }
        return "\(start)–\(end)"
    }

    private static func timeLabel(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }
}

struct GanttViewport: Equatable, Sendable {
    static let full = GanttViewport(start: 0, length: 1)
    static let defaultMinimumLength = 0.125
    private static let absoluteMinimumLength =
        1 / (366.0 * 24 * 60)

    let start: Double
    let length: Double

    var end: Double {
        start + length
    }

    var zoomScale: Double {
        1 / length
    }

    var isFull: Bool {
        length >= 0.999
    }

    init(start: Double, length: Double) {
        let clampedLength = min(
            1,
            max(Self.absoluteMinimumLength, length)
        )
        self.length = clampedLength
        self.start = min(
            1 - clampedLength,
            max(0, start)
        )
    }

    func panning(
        translation: Double,
        viewportWidth: Double
    ) -> GanttViewport {
        guard viewportWidth > 0 else { return self }
        return GanttViewport(
            start: start
                - translation / viewportWidth * length,
            length: length
        )
    }

    func magnifying(
        by factor: Double,
        anchor: Double = 0.5,
        minimumLength: Double = Self.defaultMinimumLength
    ) -> GanttViewport {
        let safeFactor = max(0.01, factor)
        let clampedMinimumLength = min(
            1,
            max(Self.absoluteMinimumLength, minimumLength)
        )
        let newLength = min(
            1,
            max(clampedMinimumLength, length / safeFactor)
        )
        let clampedAnchor = min(1, max(0, anchor))
        let anchorPosition = start + length * clampedAnchor
        return GanttViewport(
            start: anchorPosition - newLength * clampedAnchor,
            length: newLength
        )
    }

    static func oneMinuteMinimumLength(
        for totalDuration: TimeInterval
    ) -> Double {
        guard totalDuration > 60 else { return 1 }
        return min(
            1,
            max(absoluteMinimumLength, 60 / totalDuration)
        )
    }

    func fitting(
        visibleDuration: TimeInterval,
        within totalDuration: TimeInterval,
        anchor: Double = 0.5
    ) -> GanttViewport {
        let clampedAnchor = min(1, max(0, anchor))
        let newLength = min(
            1,
            max(
                Self.oneMinuteMinimumLength(for: totalDuration),
                visibleDuration / max(60, totalDuration)
            )
        )
        let anchorPosition = start + length * clampedAnchor
        return GanttViewport(
            start: anchorPosition - newLength * clampedAnchor,
            length: newLength
        )
    }

    func focusing(
        start: Double,
        length: Double,
        paddingFraction: Double = 0.16,
        minimumLength: Double
    ) -> GanttViewport {
        let clampedBlockLength = max(0, length)
        let padding = max(
            minimumLength * 0.5,
            clampedBlockLength * paddingFraction
        )
        let focusedLength = min(
            1,
            max(minimumLength, clampedBlockLength + padding * 2)
        )
        return GanttViewport(
            start: start - padding,
            length: focusedLength
        )
    }
}

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
