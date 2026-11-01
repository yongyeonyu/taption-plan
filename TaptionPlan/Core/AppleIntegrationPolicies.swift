import Foundation
import TaptionPlanCore

enum CalendarSyncPolicy {
    static let automaticRefreshInterval: TimeInterval = 6 * 60 * 60

    static func reconciledCalendarIDs(
        existing: [String],
        live: [String]
    ) -> [String] {
        guard !live.isEmpty else { return existing }
        let liveIDs = Set(live)
        let retained = existing.filter(liveIDs.contains)
        return retained.isEmpty ? live : retained
    }

    static func hasCompleteSelection(
        selected: Set<String>,
        live: Set<String>
    ) -> Bool {
        selected.isEmpty || selected.isSubset(of: live)
    }

    static func deduplicatedEvents(
        _ events: [CalendarRecord]
    ) -> [CalendarRecord] {
        var seen = Set<String>()
        return events.filter { event in
            seen.insert(eventIdentityKey(event)).inserted
        }
    }

    static func mergingEvents(
        existing: [CalendarRecord],
        fresh: [CalendarRecord],
        in span: TimeSpan,
        liveCalendarIDs: Set<String>
    ) -> [CalendarRecord] {
        let fetched = deduplicatedEvents(fresh)
        let freshIDs = Set(fetched.map(\.id))
        let freshOccurrences = Set(fetched.map(eventIdentityKey))
        var merged = existing.filter {
            liveCalendarIDs.contains($0.calendarID)
                && !freshIDs.contains($0.id)
                && !freshOccurrences.contains(eventIdentityKey($0))
                && $0.span.intersection(with: span) == nil
        }
        merged.append(contentsOf: fetched.filter { $0.isCancelled != true })
        return deduplicatedEvents(merged).sorted { $0.span.start < $1.span.start }
    }

    static func eventIdentityKey(_ event: CalendarRecord) -> String {
        let account = event.sourceIdentifier ?? "calendar:\(event.calendarID)"
        guard let external = event.externalIdentifier,
              !external.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "event|\(event.id)"
        }
        let occurrence = event.occurrenceDate.map {
            String($0.timeIntervalSinceReferenceDate.rounded())
        } ?? (event.isAllDay || event.isFloatingTime == true
            ? wallClockKey(event.originalStartDateComponents)
            : String(event.span.start.timeIntervalSinceReferenceDate.rounded()))
        return "external|\(account)|\(external)|\(occurrence)"
    }

    private static func wallClockKey(_ components: DateComponents?) -> String {
        guard let components else { return "unknown" }
        return [
            components.era,
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second,
        ].map { String($0 ?? 0) }.joined(separator: ":")
    }

    static func refreshSpans(
        requested: TimeSpan,
        includesCurrentDeviceDay: Bool,
        refreshesAutomaticRange: Bool = true,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TimeSpan] {
        guard includesCurrentDeviceDay else { return [requested] }
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        else { return [requested] }
        let automatic: TimeSpan
        if refreshesAutomaticRange,
           let start = calendar.date(byAdding: .day, value: -31, to: today),
           let end = calendar.date(byAdding: .day, value: 93, to: today) {
            automatic = TimeSpan(start: start, end: end)
        } else {
            automatic = TimeSpan(start: today, end: tomorrow)
        }
        if automatic.start <= requested.start,
           automatic.end >= requested.end {
            return [automatic]
        }
        if automatic.intersection(with: requested) != nil {
            return [TimeSpan(
                start: min(automatic.start, requested.start),
                end: max(automatic.end, requested.end)
            )]
        }
        return [automatic, requested]
    }

    static func shouldRefreshAutomaticRange(
        lastRefresh: Date?,
        now: Date,
        force: Bool = false
    ) -> Bool {
        guard !force, let lastRefresh else { return true }
        let elapsed = now.timeIntervalSince(lastRefresh)
        return elapsed < 0 || elapsed >= automaticRefreshInterval
    }
}


/// 정지 중에는 새 위치를 받아도 반영하지 않는다. 처음 위치이거나 움직임을 확신할 수 없거나
/// 일정 시간이 지나면(심장박동) 반영해서 현재 위치가 오래되지 않게 한다.
enum StationaryLocationGate {
    static let heartbeatInterval: TimeInterval = 10 * 60

    static func shouldIgnoreFixes(
        isTrulyStill: Bool,
        motionIsStationary: Bool,
        hasPreviousLocation: Bool,
        hasManualTrackingSession: Bool,
        lastAcceptedAt: Date?,
        now: Date
    ) -> Bool {
        guard isTrulyStill, motionIsStationary, hasPreviousLocation,
              !hasManualTrackingSession else { return false }
        guard let lastAcceptedAt else { return false }
        return now.timeIntervalSince(lastAcceptedAt) < heartbeatInterval
    }
}
