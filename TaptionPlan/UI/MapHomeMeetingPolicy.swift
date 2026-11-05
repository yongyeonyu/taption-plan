import Foundation
import TaptionPlanCore

/// 캘린더의 회의 일정을 화면에만 반영한다. 원본 기록은 바꾸지 않는다(MTG1105A01).
enum MapHomeMeetingPolicy {
    /// 앉아서 회의 중일 때 흔들림으로 나올 수 있는 동작. 수면·식사·실제 이동은 덮지 않는다.
    private static let replaceable: Set<MapHomeStickmanAction> = [
        .activity, .computer, .company, .walking, .walkInPlace, .workWalking,
    ]

    static func isMeeting(_ event: CalendarRecord) -> Bool { event.isMeetingLike }

    static func action(
        _ recorded: MapHomeStickmanAction,
        at date: Date,
        events: [CalendarRecord],
        travel: [TravelSegment]
    ) -> MapHomeStickmanAction {
        guard replaceable.contains(recorded),
              !travel.contains(where: { $0.span.contains(date) }),
              events.contains(where: { isMeeting($0) && $0.span.contains(date) }) else { return recorded }
        return .meeting
    }

    static func minuteSpans(events: [CalendarRecord], dayStart: Date) -> [Range<Int>] {
        events.filter(isMeeting).compactMap { event in
            let start = max(0, Int(event.span.start.timeIntervalSince(dayStart) / 60))
            let end = min(1_440, Int(event.span.end.timeIntervalSince(dayStart) / 60))
            return start < end ? start..<end : nil
        }
    }
}
