import SwiftUI

extension Color {
    /// "7B57B2" 같은 분류 색. 읽지 못하면 nil.
    init?(watchHex hex: String?) {
        guard let rgb = TaptionWatchFacePolicy.rgb(hex: hex) else { return nil }
        self.init(watchRGB: rgb)
    }

    init(watchRGB rgb: TaptionWatchFacePolicy.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func watchBackground(categoryID: String) -> Color {
        Color(watchRGB: TaptionWatchFacePolicy.background(categoryID: categoryID))
    }
}

/// 시스템이 스스로 갱신하는 시간 글자. 화면을 다시 그리지 않아도 분 단위로 맞는다.
enum WatchLiveText {
    static func elapsed(since start: Date) -> Text {
        Text(.currentDate, format: .offset(to: start, allowedFields: [.hour, .minute], maxFieldCount: 2, sign: .never))
    }

    static func until(_ date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.hour, .minute], maxFieldCount: 1))
    }
}

/// 첫 쪽. 고른 고양이가 지금 활동을 하고, 바탕은 그 대분류의 색이다.
/// 값만 받아 iPhone 값이 바뀔 때만 다시 그린다.
struct WatchNowPage: View, Equatable {
    let activity: TaptionWatchCurrentActivity?
    let hasPayload: Bool
    let catStyle: String
    let next: TaptionWatchPlanItem?
    let language: AppLanguagePreference.ResolvedLanguage

    private var categoryID: String { activity?.categoryID ?? "unconfirmed" }

    var body: some View {
        VStack(spacing: 2) {
            Image(TaptionWatchFacePolicy.catAssetName(
                style: catStyle,
                categoryID: categoryID,
                poseName: activity?.poseName
            ))
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 62)
            .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let activity {
                WatchLiveText.elapsed(since: activity.startedAt)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 2)
            if let next {
                HStack(spacing: 4) {
                    Text(next.startsAt, style: .time)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(next.title)
                        .privacySensitive()
                }
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .containerBackground(Color.watchBackground(categoryID: categoryID).gradient, for: .tabView)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if let activity { return activity.title(for: language) }
        return hasPayload
            ? language.text("확인 중", "Checking")
            : language.text("iPhone 연결 대기", "Waiting for iPhone")
    }
}

/// 오늘 지나간 시간 중 기록된 비율과 긴 분류.
struct WatchTodayPage: View, Equatable {
    let summary: TaptionWatchDaySummary?
    let date: Date
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        ScrollView {
            if let summary {
                content(summary)
            } else {
                Text(language.text("오늘 기록 없음", "No record today"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .containerBackground(Color(white: 0.1).gradient, for: .tabView)
    }

    private func content(_ summary: TaptionWatchDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ring(summary)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("오늘", "Today"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(TaptionWatchFacePolicy.durationText(summary.recordedMinutes, language: language))
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if summary.scheduledCount > 0 {
                        Label("\(summary.completedCount)/\(summary.scheduledCount)", systemImage: "checkmark.circle")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(summary.topCategories(limit: 5), id: \.categoryID) { category in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(category.title).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(TaptionWatchFacePolicy.durationText(category.minutes, language: language))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color(watchHex: category.hex) ?? .green)
                            .frame(width: max(4, proxy.size.width * fraction(category, in: summary)))
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    private func ring(_ summary: TaptionWatchDaySummary) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 6)
            ForEach(TaptionWatchFacePolicy.daySegments(summary), id: \.categoryID) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(Color(watchHex: segment.hex) ?? .green, lineWidth: 6)
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int((summary.recordedFraction(at: date) * 100).rounded()))%")
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .padding(3)
    }

    private func fraction(_ category: TaptionWatchCategoryMinutes, in summary: TaptionWatchDaySummary) -> CGFloat {
        guard summary.recordedMinutes > 0 else { return 0 }
        return min(1, CGFloat(category.minutes) / CGFloat(summary.recordedMinutes))
    }
}

/// 진행 중인 일정과 남은 일정. 고치기는 iPhone에서 한다.
struct WatchAgendaPage: View, Equatable {
    let items: [TaptionWatchPlanItem]
    let date: Date
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("일정", "Schedule"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if items.isEmpty {
                    Text(language.text("다음 일정 없음", "No upcoming plan"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70)
                }
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 6)
        }
        .containerBackground(Color(white: 0.1).gradient, for: .tabView)
    }

    private func row(_ item: TaptionWatchPlanItem) -> some View {
        let isRunning = item.startsAt <= date
        let tint = Color(watchHex: item.categoryHex) ?? .white
        return HStack(spacing: 7) {
            Capsule()
                .fill(tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.startsAt, style: .time)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Spacer(minLength: 2)
                    if isRunning {
                        Text(language.text("진행 중", "In progress"))
                            .foregroundStyle(.green)
                    } else {
                        WatchLiveText.until(item.startsAt)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .privacySensitive()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(isRunning ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    TabView {
        WatchNowPage(
            activity: TaptionWatchCurrentActivity(categoryID: "work", koreanTitle: "업무", englishTitle: "Work", startedAt: .now.addingTimeInterval(-4_000)),
            hasPayload: true, catStyle: "calico", next: nil, language: .korean
        )
        WatchTodayPage(
            summary: TaptionWatchDaySummary(
                date: .now, scheduledCount: 3, completedCount: 1, recordedMinutes: 410, activeMinutes: 60,
                categories: [
                    TaptionWatchCategoryMinutes(categoryID: "work", title: "업무", hex: "5B9BD5", minutes: 240),
                    TaptionWatchCategoryMinutes(categoryID: "movement", title: "이동", hex: "E08A3C", minutes: 60),
                ]
            ),
            date: .now, language: .korean
        )
    }
    .tabViewStyle(.verticalPage)
}
