import Foundation

/// 화면에서 읽은 일정을 판정에 잇고, 사용자가 고른 제목 분류를 저장한다(CAL1103A01).
extension AppModel {
    /// 화면이 그날 일정을 읽을 때 부른다. 일정이 실제로 바뀐 때만 다시 판정한다.
    func applyDayCalendarEvents(_ events: [CalendarRecord], on day: Date, fromGoogle: Bool) async {
        guard acceptsDataMutation(), fromGoogle else { return }
        let merged = CalendarSyncPolicy.mergingGoogleEvents(
            existing: snapshot.calendarEvents,
            fresh: events,
            in: dayTimeSpan(day)
        )
        guard merged != snapshot.calendarEvents else { return }
        snapshot.calendarEvents = merged
        await reclassifyCalendarDay(day)
    }

    /// 사용자가 고른 분류. `detailID`가 nil이면 분류 안 함이다. 자동으로 되돌리려면 `clearCalendarTitleDetail`.
    func setCalendarTitleDetail(_ detailID: String?, title: String, on day: Date) async {
        snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key(title)] =
            CalendarTitleDetail(detailID: detailID)
        await reclassifyCalendarDay(day)
    }

    func clearCalendarTitleDetail(title: String, on day: Date) async {
        snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key(title)] = nil
        await reclassifyCalendarDay(day)
    }

    func disconnectGoogleCalendar() async {
        GoogleCalendarAccount.shared.disconnect()
        snapshot.calendarEvents.removeAll(where: \.isGoogleAccountEvent)
        snapshot.actuals = snapshot.actuals.map { actual in
            var cleaned = actual
            cleaned.evidence = CalendarTitleClassification.withoutCalendarTitleEvidence(actual.evidence)
            return cleaned
        }
        await reclassifyCalendarDay(selectedDate)
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
