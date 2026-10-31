import EventKit
import Foundation
import TaptionPlanCore

// MARK: - Calendar


@MainActor
final class AppleCalendarService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func permissionState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        case .fullAccess, .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendars() -> [(id: String, title: String)] {
        eventStore.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func events(
        in span: TimeSpan,
        selectedCalendarIDs: Set<String>
    ) async -> [CalendarRecord]? {
        let start = span.start
        let end = span.end
        let selected = selectedCalendarIDs
        return await Task.detached(priority: .utility) {
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .event).filter {
                selected.isEmpty || selected.contains($0.calendarIdentifier)
            }
            let available = Set(calendars.map(\.calendarIdentifier))
            guard CalendarSyncPolicy.hasCompleteSelection(
                selected: selected,
                live: available
            ) else {
                return nil
            }
            let predicate = eventStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: calendars
            )
            let dateComponents: Set<Calendar.Component> = [
                .era, .year, .month, .day, .hour, .minute, .second,
                .nanosecond,
            ]
            return eventStore.events(matching: predicate).map { event in
                var eventCalendar = Calendar.autoupdatingCurrent
                if let timeZone = event.timeZone {
                    eventCalendar.timeZone = timeZone
                }
                let originalStartDateComponents = eventCalendar.dateComponents(
                    dateComponents,
                    from: event.startDate
                )
                let originalEndDateComponents = eventCalendar.dateComponents(
                    dateComponents,
                    from: event.endDate
                )
                let stableID = event.eventIdentifier ?? [
                    event.calendar.calendarIdentifier,
                    event.calendarItemExternalIdentifier
                        ?? event.calendarItemIdentifier,
                    String(event.startDate.timeIntervalSinceReferenceDate),
                ].joined(separator: "|")
                return CalendarRecord(
                    id: stableID,
                    calendarID: event.calendar.calendarIdentifier,
                    title: event.title ?? "제목 없는 일정",
                    span: TimeSpan(start: event.startDate, end: event.endDate),
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title,
                    calendarColorHex: Self.hex(event.calendar.cgColor),
                    sourceTitle: event.calendar.source.title,
                    sourceIdentifier: event.calendar.source.sourceIdentifier,
                    timeZoneIdentifier: event.timeZone?.identifier,
                    isFloatingTime: !event.isAllDay && event.timeZone == nil,
                    originalStartDateComponents: originalStartDateComponents,
                    originalEndDateComponents: originalEndDateComponents,
                    externalIdentifier: event.calendarItemExternalIdentifier,
                    recurrenceIdentifier: Self.recurrenceIdentifier(
                        for: event.recurrenceRules
                    ),
                    occurrenceDate: event.occurrenceDate,
                    attendeeCount: event.attendees?.count,
                    isCancelled: event.status == .canceled
                ).normalizedForDisplay()
            }
        }.value
    }

    private nonisolated static func recurrenceIdentifier(
        for rules: [EKRecurrenceRule]?
    ) -> String? {
        guard let rules, !rules.isEmpty else { return nil }
        return rules.map { rule in
            let recurrenceEnd: String
            if let endDate = rule.recurrenceEnd?.endDate {
                recurrenceEnd = String(
                    endDate.timeIntervalSinceReferenceDate
                )
            } else {
                recurrenceEnd = "count:\(rule.recurrenceEnd?.occurrenceCount ?? 0)"
            }
            let daysOfTheWeek = rule.daysOfTheWeek?.map {
                "\($0.dayOfTheWeek.rawValue):\($0.weekNumber)"
            }.joined(separator: ",") ?? ""
            let daysOfTheMonth = rule.daysOfTheMonth?
                .map(String.init)
                .joined(separator: ",") ?? ""
            let monthsOfTheYear = rule.monthsOfTheYear?
                .map(String.init)
                .joined(separator: ",") ?? ""
            let weeksOfTheYear = rule.weeksOfTheYear?
                .map(String.init)
                .joined(separator: ",") ?? ""
            let daysOfTheYear = rule.daysOfTheYear?
                .map(String.init)
                .joined(separator: ",") ?? ""
            let setPositions = rule.setPositions?
                .map(String.init)
                .joined(separator: ",") ?? ""
            let values = [
                String(rule.frequency.rawValue),
                String(rule.interval),
                String(rule.firstDayOfTheWeek),
                daysOfTheWeek,
                daysOfTheMonth,
                monthsOfTheYear,
                weeksOfTheYear,
                daysOfTheYear,
                setPositions,
                recurrenceEnd,
            ]
            return values.joined(separator: "|")
        }.joined(separator: ";")
    }

    func addPlan(
        _ plan: PlanRecord,
        to calendarID: String? = nil
    ) throws -> String {
        let event = EKEvent(eventStore: eventStore)
        event.title = plan.title
        event.startDate = plan.span.start
        event.endDate = plan.span.end
        event.calendar = calendarID.flatMap { id in
            eventStore.calendars(for: .event).first {
                $0.calendarIdentifier == id
            }
        } ?? eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    private nonisolated static func hex(_ color: CGColor) -> String? {
        guard let components = color.components else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if components.count >= 3 {
            red = components[0]
            green = components[1]
            blue = components[2]
        } else if let gray = components.first {
            red = gray
            green = gray
            blue = gray
        } else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}
