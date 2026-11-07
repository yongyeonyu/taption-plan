import Foundation

/// 시작·끝 구간. 저장 키는 `start`·`end`이고 끝은 시작보다 앞서지 않는다.
public struct TimeSpan: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    @inlinable
    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    @inlinable
    public var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    /// 겹치는 구간을 병합한 총 시간(같은 초를 두 번 세지 않는다).
    public static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    @inlinable
    public func intersection(with other: TimeSpan) -> TimeSpan? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard lower < upper else { return nil }
        return TimeSpan(start: lower, end: upper)
    }

    /// NaN 시각이나 NaN 경계는 어떤 구간에도 속하지 않는다. Date 비교의 NaN 결과는 기기 런타임마다 다르다.
    @inlinable
    public func contains(_ date: Date) -> Bool {
        guard !date.timeIntervalSinceReferenceDate.isNaN, !isNaNBounded else { return false }
        return start <= date && date <= end
    }

    @inlinable
    public var isNaNBounded: Bool {
        start.timeIntervalSinceReferenceDate.isNaN || end.timeIntervalSinceReferenceDate.isNaN
    }
}
