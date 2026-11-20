import Foundation
import TaptionPlanCore

/// 시계 묶음(평상시 10분 안팎, 늦게 오면 수십 분) 가운데 집에 있던 시간(HSW1120A01).
///
/// 예전에는 묶음이 집 체류와 1초만 겹쳐도 묶음 전체를 집으로 봐서, 집을 나서 차를 타고
/// 회사에 도착한 시간까지 「집안일」로 적혔다. 이제 집에 있던 부분만 돌려주고, 그 부분이
/// 너무 짧으면 집으로 보지 않는다.
enum WatchHomeWindow {
    /// 묶음의 일부만 집일 때, 이보다 짧게 겹치면 집에서 한 일로 보지 않는다.
    static let minimumSeconds: TimeInterval = 60

    /// - Parameters:
    ///   - summary: 시계 묶음의 시간.
    ///   - homeStays: 집 체류 시간들.
    ///   - otherStays: 집이 아닌 곳의 체류 시간들.
    ///   - route: 묶음의 시계 위치 표본(시각, 집 반경 안인지).
    ///   - latestReadingAtHome: 묶음이 끝난 무렵 휴대폰 최근 위치가 집 반경 안인지.
    static func window(
        summary: TimeSpan,
        homeStays: [TimeSpan],
        otherStays: [TimeSpan],
        route: [(Date, Bool)],
        latestReadingAtHome: Bool
    ) -> TimeSpan? {
        // ① 집 체류와 겹친 부분.
        let overlaps = homeStays.compactMap { $0.intersection(with: summary) }
        if let start = overlaps.map(\.start).min(), let end = overlaps.map(\.end).max() {
            return accepted(TimeSpan(start: start, end: end), of: summary)
        }
        // ② 시계 위치가 있으면 그것만 믿는다. 집 안 표본이 없으면 집이 아니다.
        if !route.isEmpty {
            let inside = route.filter(\.1).map(\.0)
            guard let first = inside.min(), let last = inside.max() else { return nil }
            if inside.count == route.count { return summary }
            return accepted(TimeSpan(start: max(summary.start, first), end: min(summary.end, last)), of: summary)
        }
        // ③ 끝날 무렵 휴대폰이 집에 있었다. 묶음 안에 다른 곳 체류가 있으면 그 뒤만 집이다.
        guard latestReadingAtHome else { return nil }
        let lastOtherEnd = otherStays.compactMap { $0.intersection(with: summary)?.end }.max()
        return accepted(TimeSpan(start: max(summary.start, lastOtherEnd ?? summary.start), end: summary.end), of: summary)
    }

    /// 이미 저장된 자동 「집안일」 기록에서 집 밖(다른 곳 체류·차량 이동)과 겹친 부분을 걷어 낸다.
    /// 예전 판정으로 출근길·회사 시간까지 늘어난 기록을 고친다. 사용자가 고친 기록은 그대로 둔다.
    static func trimmingAwayFromHome(_ records: [ActualRecord], away: [TimeSpan], asOf now: Date) -> [ActualRecord] {
        guard !away.isEmpty else { return records }
        return records.compactMap { record in
            guard record.source == .appleWatch, record.sensorChunkID != nil,
                  record.behavior == "housework", !ActualRecord.userOwned(record) else { return record }
            var start = record.startedAt
            var end = record.endedAt ?? now
            for stay in away.sorted(by: { $0.start < $1.start }) where stay.start < end && start < stay.end {
                if stay.start <= start { start = max(start, stay.end) } else { end = min(end, stay.start) }
                guard start < end else { break }
            }
            guard end.timeIntervalSince(start) >= minimumSeconds else { return nil }
            var trimmed = record
            trimmed.startedAt = start
            if record.endedAt != nil || end < now { trimmed.endedAt = end }
            return trimmed
        }
    }

    /// 묶음 전체가 집이면 짧아도 그대로 쓴다. 일부만 집일 때 그 부분이 너무 짧으면 버린다.
    private static func accepted(_ span: TimeSpan, of summary: TimeSpan) -> TimeSpan? {
        if span == summary { return span }
        guard span.end > span.start else { return nil }
        return span.end.timeIntervalSince(span.start) >= minimumSeconds ? span : nil
    }
}
