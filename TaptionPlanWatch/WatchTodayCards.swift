import SwiftUI

extension Color {
    /// "7B57B2" 같은 분류 색. 읽지 못하면 nil.
    init?(watchHex hex: String?) {
        guard let hex, let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum WatchDurationText {
    static func text(_ minutes: Int, language: AppLanguagePreference.ResolvedLanguage) -> String {
        let hours = max(0, minutes) / 60
        let remainder = max(0, minutes) % 60
        if hours == 0 { return language.text("\(remainder)분", "\(remainder) min") }
        if remainder == 0 { return language.text("\(hours)시간", "\(hours) hr") }
        return language.text("\(hours)시간 \(remainder)분", "\(hours) hr \(remainder) min")
    }
}

private struct WatchCard: ViewModifier {
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
    }
}

/// 지금 하고 있는 대분류. iPhone이 바뀐 값을 밀어 주면 몇 초 안에 여기까지 온다.
struct WatchNowCard: View {
    let activity: TaptionWatchCurrentActivity?
    let hasPayload: Bool
    let date: Date
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(language.text("지금", "Now"))
                Spacer(minLength: 2)
                if let activity {
                    Text(WatchDurationText.text(Int(max(0, date.timeIntervalSince(activity.startedAt)) / 60), language: language))
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .modifier(WatchCard(tint: .green))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if let activity { return activity.title(for: language) }
        return hasPayload
            ? language.text("확인 중", "Checking")
            : language.text("iPhone 연결 대기", "Waiting for iPhone")
    }
}

/// 오늘 기록 시간과 긴 분류 3개.
struct WatchTodayCard: View {
    let summary: TaptionWatchDaySummary
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text("오늘", "Today"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(WatchDurationText.text(summary.recordedMinutes, language: language))
            }
            .font(.footnote.weight(.semibold))
            ForEach(summary.topCategories(), id: \.categoryID) { category in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(category.title).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(WatchDurationText.text(category.minutes, language: language))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color(watchHex: category.hex) ?? .green)
                            .frame(width: max(4, proxy.size.width * fraction(category)))
                    }
                    .frame(height: 4)
                }
            }
        }
        .modifier(WatchCard())
        .accessibilityElement(children: .combine)
    }

    private func fraction(_ category: TaptionWatchCategoryMinutes) -> CGFloat {
        guard summary.recordedMinutes > 0 else { return 0 }
        return min(1, CGFloat(category.minutes) / CGFloat(summary.recordedMinutes))
    }
}

struct WatchNextCard: View {
    let item: TaptionWatchPlanItem
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(language.text("다음", "Next"))
                Spacer(minLength: 2)
                Text(item.startsAt.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
        }
        .modifier(WatchCard(tint: Color(watchHex: item.categoryHex) ?? .white))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 8) {
            WatchNowCard(
                activity: TaptionWatchCurrentActivity(categoryID: "work", koreanTitle: "업무", englishTitle: "Work", startedAt: .now.addingTimeInterval(-4_000)),
                hasPayload: true, date: .now, language: .korean
            )
            WatchTodayCard(
                summary: TaptionWatchDaySummary(
                    date: .now, scheduledCount: 3, completedCount: 1, recordedMinutes: 410, activeMinutes: 60,
                    categories: [
                        TaptionWatchCategoryMinutes(categoryID: "work", title: "업무", hex: "5B9BD5", minutes: 240),
                        TaptionWatchCategoryMinutes(categoryID: "movement", title: "이동", hex: "E08A3C", minutes: 60),
                    ]
                ),
                language: .korean
            )
        }
    }
}
