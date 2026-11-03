import Foundation

/// 화면에서 읽은 일정을 판정에 잇고, 제목을 분류한다(CAL1103A01).
extension AppModel {
    private static let titleClassificationLimit = 20

    /// 화면이 그날 일정을 읽을 때 부른다. 일정이나 제목 분류가 실제로 바뀐 때만 다시 판정한다.
    func applyDayCalendarEvents(_ events: [CalendarRecord], on day: Date, fromGoogle: Bool) async {
        guard acceptsDataMutation() else { return }
        var changed = false
        if fromGoogle {
            let merged = CalendarSyncPolicy.mergingGoogleEvents(
                existing: snapshot.calendarEvents,
                fresh: events,
                in: dayTimeSpan(day)
            )
            if merged != snapshot.calendarEvents {
                snapshot.calendarEvents = merged
                changed = true
            }
        }
        let classified = await classifyCalendarTitles(events)
        guard changed || classified else { return }
        await reclassifyCalendarDay(day)
    }

    /// 사용자가 고른 분류. `detailID`가 nil이면 분류 안 함이다. 자동으로 되돌리려면 `clearCalendarTitleDetail`.
    func setCalendarTitleDetail(_ detailID: String?, title: String, on day: Date) async {
        snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key(title)] =
            CalendarTitleDetail(detailID: detailID, source: .user)
        await reclassifyCalendarDay(day)
    }

    func clearCalendarTitleDetail(title: String, on day: Date) async {
        snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key(title)] = nil
        _ = await classifyCalendarTitles(snapshot.calendarEvents.filter { $0.title == title })
        await reclassifyCalendarDay(day)
    }

    func disconnectGoogleCalendar() async {
        GoogleCalendarAccount.shared.disconnect()
        snapshot.calendarEvents.removeAll(where: \.isGoogleAccountEvent)
        await reclassifyCalendarDay(selectedDate)
    }

    private func classifyCalendarTitles(_ events: [CalendarRecord]) async -> Bool {
        guard CalendarTitleIntelligence.isAvailable else { return false }
        let stored = snapshot.settings.calendarTitleDetails
        var seen = Set<String>()
        let titles = events
            .filter { !$0.isAllDay && $0.isCancelled != true && stored[CalendarTitleClassification.key($0.title)] == nil }
            .filter { seen.insert(CalendarTitleClassification.key($0.title)).inserted }
            .map(\.title)
            .prefix(Self.titleClassificationLimit)
        var changed = false
        for title in titles {
            guard !Task.isCancelled, let answer = await CalendarTitleIntelligence.classify(title) else { continue }
            let key = CalendarTitleClassification.key(title)
            // 기다리는 동안 사용자가 고른 값은 덮지 않는다.
            guard snapshot.settings.calendarTitleDetails[key] == nil else { continue }
            let detailID: String? = if case .detail(let id) = answer { id } else { nil }
            snapshot.settings.calendarTitleDetails[key] = CalendarTitleDetail(detailID: detailID, source: .appleIntelligence)
            changed = true
        }
        return changed
    }

    private func dayTimeSpan(_ day: Date) -> TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        return TimeSpan(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    private func reclassifyCalendarDay(_ day: Date) async {
        sensorRefreshFingerprints.removeValue(forKey: Calendar.autoupdatingCurrent.startOfDay(for: day))
        await refreshSensorTimeline(containing: day)
        await persist()
    }
}
