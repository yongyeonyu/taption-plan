import Foundation

/// 다음에 판정이 바뀔 수 있는 시각을 구한다. 앱은 그 시각까지 타이머 하나만 건다(1초 폴링 금지).
public enum SeasonPackTriggers {
    /// `after` 뒤 첫 경계: 창의 시작·끝, 메뉴 아이콘의 보임 구간, 점등·소등(일몰·일출), 자정.
    public static func nextTransition(packs: [SeasonPackManifest], after: Date, windows: SeasonPackWindows) -> Date? {
        let calendar = windows.calendar
        let year = calendar.component(.year, from: after)
        var candidates: [Date] = []
        let today = calendar.startOfDay(for: after)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) { candidates.append(tomorrow) }
        for spans in windows.schedules.values { for span in spans { candidates += [span.start, span.end] } }
        for pack in packs {
            for window in pack.event.windows where windows.schedules[pack.id] == nil {
                for startYear in [year - 1, year, year + 1] {
                    if let span = windows.interval(of: window, startYear: startYear) { candidates += [span.start, span.end] }
                }
            }
            for icon in pack.menuIcons ?? [] {
                candidates += [icon.visibleFrom, icon.visibleTo].compactMap { $0.flatMap { SeasonPackDateParsing.localDateTime($0, calendar: calendar) } }
            }
            if pack.slots?.house?.lights != nil {
                for offset in 0...1 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                    let sun = windows.sun(day)
                    candidates += [sun.sunrise, sun.sunset].compactMap { $0 }
                }
            }
        }
        return candidates.filter { $0 > after }.min()
    }

    /// 분 단위 정각이 필요한 시각 조건이 있는가(없으면 일 단위 경계만 본다).
    public static func needsExactMinute(_ manifest: SeasonPackManifest) -> Bool {
        let plain: Set<String?> = [nil, "00:00", "23:59"]
        return manifest.event.windows.contains { !plain.contains($0.fromTime) || !plain.contains($0.toTime) }
    }
}
