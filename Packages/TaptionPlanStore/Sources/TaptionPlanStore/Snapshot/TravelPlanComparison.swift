import Foundation

/// 여행 계획과 실제 기록의 비교(TVC1112A01). 하루의 분(0…1440) 구간끼리 견준다.
/// 장소는 아직 견주지 않고 시각과 종류(이동인지 머묾인지)만 본다.
public enum TravelPlanComparison {
    public struct Span: Hashable, Sendable {
        public var id: String
        public var start: Int
        public var end: Int
        /// 이동이면 true, 머무는 일정·기록이면 false.
        public var isMove: Bool

        public init(id: String, start: Int, end: Int, isMove: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.isMove = isMove
        }
    }

    public enum Status: String, Sendable {
        /// 아직 오지 않은 일정.
        case pending
        /// 지금 하고 있어야 할 시각인데 맞는 기록이 아직 없다.
        case underway
        /// 계획대로 했다.
        case done
        /// 했지만 시작이 `lateMinutes`보다 늦었다.
        case late
        /// 시각이 지났는데 맞는 기록이 없다.
        case skipped
    }

    public struct Result: Hashable, Sendable {
        /// 계획 일정 id → 상태.
        public var statuses: [String: Status]
        /// 계획에 없던 머묾(실제 기록 id).
        public var unplanned: [String]
    }

    /// 일정 앞뒤로 이만큼은 같은 시각으로 본다.
    public static let slackMinutes = 30
    public static let lateMinutes = 15
    /// 계획에 없던 방문으로 치는 가장 짧은 머묾.
    public static let unplannedMinutes = 20

    /// `nowMinute`는 그날의 지금(지난 날이면 1440, 오지 않은 날이면 0).
    public static func compare(plan: [Span], actual: [Span], nowMinute: Int) -> Result {
        var statuses: [String: Status] = [:]
        for item in plan where item.end > item.start {
            let from = item.start - slackMinutes, to = item.end + slackMinutes
            let needed = min(10, max(1, (item.end - item.start) / 2))
            let matches = actual.filter { $0.isMove == item.isMove && overlap($0, from, to) >= needed }
            if let first = matches.map(\.start).min() {
                statuses[item.id] = first - item.start > lateMinutes ? .late : .done
            } else if nowMinute >= to {
                statuses[item.id] = .skipped
            } else {
                statuses[item.id] = nowMinute >= item.start ? .underway : .pending
            }
        }
        let unplanned = actual.filter { record in
            !record.isMove && record.end - record.start >= unplannedMinutes
                && !plan.contains { !$0.isMove && overlap(record, $0.start - slackMinutes, $0.end + slackMinutes) > 0 }
        }
        return Result(statuses: statuses, unplanned: unplanned.map(\.id))
    }

    private static func overlap(_ span: Span, _ from: Int, _ to: Int) -> Int {
        max(0, min(span.end, to) - max(span.start, from))
    }
}
