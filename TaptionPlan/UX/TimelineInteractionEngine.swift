import Foundation

enum TimelineZoomPreset: String, CaseIterable, Identifiable, Sendable {
    case oneMinute = "1분"
    case fiveMinutes = "5분"
    case fifteenMinutes = "15분"
    case oneHour = "1시간"
    case threeHours = "3시간"
    case sixHours = "6시간"
    case twelveHours = "12시간"
    case oneDay = "1일"
    case threeDays = "3일"
    case oneWeek = "1주"
    case oneMonth = "1월"
    case oneYear = "1년"

    var id: Self { self }

    /// Resolution choices exposed by the schedule NLE. Yearly aggregation is
    /// a review/report concern, not an editable timeline viewport.
    static let scheduleCases: [Self] = allCases.filter { $0 != .oneYear }

    var duration: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .threeHours: 3 * 60 * 60
        case .sixHours: 6 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .threeDays: 3 * 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .oneMonth: 31 * 24 * 60 * 60
        case .oneYear: 366 * 24 * 60 * 60
        }
    }

    var detail: String {
        switch self {
        case .oneMinute: "최대 확대"
        case .fiveMinutes, .fifteenMinutes: "분 단위"
        case .oneHour, .threeHours, .sixHours, .twelveHours: "시간 단위"
        case .oneDay: "하루 전체"
        case .threeDays: "여러 날 연속"
        case .oneWeek: "주 전체"
        case .oneMonth: "월 전체"
        case .oneYear: "년 전체"
        }
    }

    var preferredScale: TimeScale {
        switch self {
        case .oneWeek:
            .week
        case .oneMonth:
            .month
        case .oneYear:
            .month
        default:
            .day
        }
    }

    static func defaultPreset(for scale: TimeScale) -> Self {
        switch scale {
        case .day: .oneHour
        case .week: .oneWeek
        case .month: .oneMonth
        case .year: .oneMonth
        }
    }

    static func nearest(to stage: GanttZoomStage) -> Self {
        switch stage {
        case .year: .oneMonth
        case .month: .oneMonth
        case .week: .oneWeek
        case .day: .oneDay
        case .hour: .oneHour
        case .fifteenMinutes: .fifteenMinutes
        case .fiveMinutes: .fiveMinutes
        case .oneMinute: .oneMinute
        }
    }

    static func nearest(to duration: TimeInterval) -> Self {
        allCases.min {
            abs(log(max(60, duration) / $0.duration))
                < abs(log(max(60, duration) / $1.duration))
        } ?? .oneDay
    }

    /// Formats the actual visible time span, including values between and
    /// beyond the menu presets.  The ruler is a readout of the live pinch
    /// result; it is not a second zoom constraint.
    static func displayLabel(for duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes < 60 {
            return "\(minutes)분"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 {
            return remainder == 0
                ? "\(hours)시간"
                : "\(hours)시간 \(remainder)분"
        }

        let days = Double(minutes) / (24 * 60)
        if days < 30 {
            let roundedDays = max(1, Int(days.rounded()))
            return "\(roundedDays)일"
        }

        if days < 365 {
            let months = max(1, Int((days / 30.4375).rounded()))
            return "\(months)개월"
        }

        let years = max(1, Int((days / 365.25).rounded()))
        return "\(years)년"
    }
}

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

/// NLE-style viewport state: the document stays immutable while pan and zoom
/// update only a center instant and visible duration. Rendering code can turn
/// this pair into a span without rebuilding source tracks or rereading data.
struct NLETimelineViewport: Equatable, Sendable {
    static let minimumDuration: TimeInterval = 60
    static let maximumScheduleDuration: TimeInterval = 31 * 24 * 60 * 60

    let centerDate: Date
    let visibleDuration: TimeInterval

    init(centerDate: Date, visibleDuration: TimeInterval) {
        self.visibleDuration = min(
            Self.maximumScheduleDuration,
            max(Self.minimumDuration, visibleDuration.isFinite
                ? visibleDuration
                : Self.minimumDuration)
        )
        self.centerDate = centerDate
    }

    var span: TimeSpan {
        let half = visibleDuration / 2
        return TimeSpan(
            start: centerDate.addingTimeInterval(-half),
            end: centerDate.addingTimeInterval(half)
        )
    }

    func panned(
        by translation: Double,
        viewportWidth: Double
    ) -> Self {
        guard viewportWidth > 0, translation.isFinite else { return self }
        return Self(
            centerDate: centerDate.addingTimeInterval(
                -translation / viewportWidth * visibleDuration
            ),
            visibleDuration: visibleDuration
        )
    }

    func magnified(
        by factor: Double,
        anchor: Double,
        maximumDuration: TimeInterval = Self.maximumScheduleDuration
    ) -> Self {
        let safeFactor = max(0.01, factor.isFinite ? factor : 1)
        let maxDuration = max(Self.minimumDuration, maximumDuration)
        let newDuration = min(
            maxDuration,
            max(Self.minimumDuration, visibleDuration / safeFactor)
        )
        let clampedAnchor = min(1, max(0, anchor.isFinite ? anchor : 0.5))
        let anchorDate = span.start.addingTimeInterval(
            visibleDuration * clampedAnchor
        )
        return Self(
            centerDate: anchorDate.addingTimeInterval(
                newDuration * (0.5 - clampedAnchor)
            ),
            visibleDuration: newDuration
        )
    }
}

/// Projects the moving visible window into a wider cached data window. Blocks
/// can then keep their cached fractions while the viewport alone moves.
enum TimelineCachedViewportProjection {
    static func viewport(
        displaySpan: TimeSpan,
        dataSpan: TimeSpan,
        viewport: GanttViewport
    ) -> GanttViewport? {
        guard displaySpan.duration > 0, dataSpan.duration > 0 else {
            return nil
        }
        let visibleStart = displaySpan.start.addingTimeInterval(
            displaySpan.duration * viewport.start
        )
        let visibleEnd = displaySpan.start.addingTimeInterval(
            displaySpan.duration * viewport.end
        )
        guard dataSpan.start <= visibleStart,
              visibleEnd <= dataSpan.end,
              visibleStart < visibleEnd else {
            return nil
        }
        return GanttViewport(
            start: visibleStart.timeIntervalSince(dataSpan.start)
                / dataSpan.duration,
            length: visibleEnd.timeIntervalSince(visibleStart)
                / dataSpan.duration
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

    static func adjust(
        _ span: TimeSpan,
        handle: TimeSliderHandle,
        delta: TimeInterval,
        snapInterval: TimeInterval,
        bounds: TimeSpan? = nil,
        minimumDuration: TimeInterval = 60
    ) -> TimeSpan {
        let step = max(60, snapInterval)
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

enum QuickPlanDraftEngine {
    static let defaultDuration: TimeInterval = 30 * 60
    static let adjustmentStep: TimeInterval = 5 * 60

    static func roundedUpToHalfHour(_ date: Date) -> Date {
        let interval = defaultDuration
        return Date(
            timeIntervalSinceReferenceDate:
                ceil(date.timeIntervalSinceReferenceDate / interval) * interval
        )
    }

    static func resolvedTitle(
        subcategory: String,
        middleCategory: String
    ) -> String? {
        let subcategory = subcategory.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !subcategory.isEmpty { return subcategory }

        let middleCategory = middleCategory.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return middleCategory.isEmpty ? nil : middleCategory
    }
}
