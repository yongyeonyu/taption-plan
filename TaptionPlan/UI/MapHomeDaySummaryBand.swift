import SwiftUI

/// 하루 요약 띠(HUX1116A06, 시험 옵션·기본 끔): 아래 메뉴 위 「머문 곳 4 · 6,240걸음 · ₩18,500」 한 줄. 누르면 하루 요약.
@MainActor
enum MapHomeDaySummaryBandPolicy {
    static let storageKey = "mapHomeDaySummaryBand"

    /// 띠 글. 값이 없는 칸은 빼고, 셋 다 없으면 nil(띠를 띄우지 않음).
    static func summary(places: Int, steps: Int?, spent: Double, language: MapHomeLanguage) -> String? {
        var parts: [String] = []
        if places > 0 { parts.append(language.text("머문 곳 \(places)", "\(places) places")) }
        if let steps, steps > 0 { parts.append(language.text("\(steps.formatted())걸음", "\(steps.formatted()) steps")) }
        if spent > 0 { parts.append(LedgerMoney.text(spent, language: language)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 띠 글을 하루 자료·가계부가 바뀔 때(오늘이면 1분마다)만 다시 센다. 홈이 다시 그려질 때마다 걸음을 다시 세지 않는다.
final class MapHomeDaySummaryBandCache {
    struct Key: Equatable {
        var revision: UInt64
        var day: Date
        var ledgerRevision: Int
        var english: Bool
        var minute: Int
    }

    private var key: Key?
    private var value: String?

    func value(for next: Key, compute: () -> String?) -> String? {
        if next == key { return value }
        key = next
        value = compute()
        return value
    }
}

struct MapHomeDaySummaryBand: View, Equatable {
    let language: MapHomeLanguage
    let text: String
    let onTap: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.text == rhs.text
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(Color.tpAccent)
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(Color.tpInk.opacity(0.55))
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 14)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .taptionRaised(.rounded(TaptionCorner.large), fill: Color.tpSurface, gloss: false)
        .accessibilityLabel(language.text("하루 요약", "Day summary") + ", " + text)
        .accessibilityHint(language.text("누르면 하루 요약을 엽니다", "Opens the day summary"))
        .accessibilityIdentifier("mapHomeDaySummaryBand")
    }
}

extension MapHomeView {
    var daySummaryBandText: String? {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let isToday = calendar.isDateInToday(model.selectedDate)
        let key = MapHomeDaySummaryBandCache.Key(
            revision: model.dayProjectionRevision,
            day: calendar.startOfDay(for: model.selectedDate),
            ledgerRevision: LedgerBook.shared.revision,
            english: language == .english,
            minute: isToday ? Int(Date.now.timeIntervalSince1970 / 60) : 0
        )
        return daySummaryBandCache.value(for: key) {
            MapHomeDaySummaryBandPolicy.summary(
                places: currentDayDataSnapshot?.places.count ?? 0,
                steps: MapHomeCounterTimelinePolicy.stepCount(readings: currentDayReadings, cutoff: nil),
                spent: LedgerDaySpending.total(day: model.selectedDate, cutoff: .now),
                language: language
            )
        }
    }
}
