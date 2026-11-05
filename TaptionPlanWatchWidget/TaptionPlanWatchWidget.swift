import SwiftUI
import TaptionPlanCore
import WidgetKit

@main
struct TaptionPlanWatchWidgetBundle: WidgetBundle {
    init() {
        TaptionPlanSharedContainer.configure(
            provider: FixedTaptionPlanAppGroupProvider(
                identifier: TaptionPlanSharedContainer.defaultAppGroupIdentifier
            )
        )
    }

    var body: some Widget {
        TaptionWatchStatusWidget()
    }
}

private struct TaptionWatchWidgetEntry: TimelineEntry {
    let date: Date
    let payload: TaptionWatchPayload?
    let measurement: TaptionWatchMeasurementSnapshot?
}

private struct TaptionWatchWidgetProvider: TimelineProvider {
    /// 워치 컴플리케이션은 연속 갱신이 없다. 항목을 미리 만들어 두고
    /// 시스템이 그 시각에 다시 그린다. 여기서 늙는 값은 "몇 분 전"뿐이라
    /// 5분 간격이면 표시가 어긋나지 않는다. 새 측정이 나오면 워치 앱이
    /// 타임라인을 다시 불러 앞당긴다.
    private static let step: TimeInterval = 5 * 60
    private static let horizon: TimeInterval = 60 * 60

    func placeholder(in context: Context) -> TaptionWatchWidgetEntry {
        TaptionWatchWidgetEntry(
            date: .now,
            payload: .widgetPlaceholder,
            measurement: .widgetPlaceholder
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (TaptionWatchWidgetEntry) -> Void
    ) {
        completion(
            TaptionWatchWidgetEntry(
                date: .now,
                payload: context.isPreview
                    ? .widgetPlaceholder
                    : TaptionWatchWidgetStore.read(),
                measurement: context.isPreview
                    ? .widgetPlaceholder
                    : TaptionWatchMeasurementStore.read()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TaptionWatchWidgetEntry>) -> Void
    ) {
        let now = Date.now
        let end = now.addingTimeInterval(Self.horizon)
        let payload = TaptionWatchWidgetStore.read()
        let measurement = TaptionWatchMeasurementStore.read()
        // 알림 줄은 계획 시작 시각에 사라진다. 그 경계도 항목으로 넣어
        // 5분 격자 때문에 늦게 지워지지 않게 한다.
        let boundaries = TaptionWatchLiveItemPolicy
            .upcoming(payload?.items ?? [], at: now)
            .map(\.startsAt)
            .filter { now < $0 && $0 <= end }
        let dates = Set(
            stride(from: now, through: end, by: Self.step) + boundaries
        )
        var entries = dates.sorted().map {
            TaptionWatchWidgetEntry(
                date: $0,
                payload: payload,
                measurement: measurement
            )
        }
        if entries.isEmpty {
            // 항목이 없는 타임라인은 WidgetKit이 갱신을 멈추게 만든다.
            entries = [
                TaptionWatchWidgetEntry(
                    date: now,
                    payload: payload,
                    measurement: measurement
                ),
            ]
        }
        completion(Timeline(entries: entries, policy: .after(end)))
    }
}

private struct TaptionWatchStatusWidget: Widget {
    // 이미 얹어 둔 컴플리케이션이 끊기지 않도록 kind는 바꾸지 않는다.
    let kind = TaptionWatchWidgetKind.status

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaptionWatchWidgetProvider()) {
            TaptionWatchWidgetView(entry: $0)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(
            AppLanguagePreference.text(
                korean: "BOKKI 오늘",
                english: "BOKKI Today"
            )
        )
        .description(
            AppLanguagePreference.text(
                korean: "지금 활동과 다음 일정, 오늘 기록을 표시합니다.",
                english: "Shows your current activity, next plan, and today's record."
            )
        )
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

private struct TaptionWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaptionWatchWidgetEntry

    /// 저장소 읽기와 JSON 디코딩을 뷰 본문 평가마다 반복하면 컴플리케이션의
    /// 좁은 실행 예산을 넘긴다. 한 번만 읽어 두고 재사용한다.
    private let resolvedPayload: TaptionWatchPayload?
    private let resolvedMeasurement: TaptionWatchMeasurementSnapshot?

    private var language: AppLanguagePreference.ResolvedLanguage {
        AppLanguagePreference.resolve(rawValue: resolvedPayload?.languagePreference)
    }

    init(entry: TaptionWatchWidgetEntry) {
        self.entry = entry
        resolvedPayload = Self.freshest(
            TaptionWatchWidgetStore.read(),
            entry.payload,
            date: \.generatedAt
        )
        resolvedMeasurement = Self.freshest(
            TaptionWatchMeasurementStore.read(),
            entry.measurement,
            date: \.updatedAt
        )
    }

    /// 앱이 방금 남긴 값과 타임라인 항목에 실려 온 값 중 새것을 고른다.
    private static func freshest<Value>(
        _ stored: Value?,
        _ entryValue: Value?,
        date: KeyPath<Value, Date>
    ) -> Value? {
        switch (stored, entryValue) {
        case let (stored?, entryValue?):
            stored[keyPath: date] >= entryValue[keyPath: date]
                ? stored
                : entryValue
        case let (stored?, nil):
            stored
        default:
            entryValue
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            default:
                rectangularView
            }
        }
        .environment(\.locale, language.locale)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(activityTitle, systemImage: activitySymbolName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let alert {
                Label(alert.title, systemImage: alert.symbolName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            } else if let next = nextPlan {
                HStack(spacing: 3) {
                    Text(next.startsAt, style: .time)
                        .monospacedDigit()
                    Text(next.title)
                        .lineLimit(1)
                        .privacySensitive()
                }
                .font(.caption2.weight(.semibold))
            }

            Text(language.text("오늘 \(duration(summary.recordedMinutes))", "Today \(duration(summary.recordedMinutes))"))
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 오늘 지나간 시간 중 기록된 비율.
    private var circularView: some View {
        let fraction = summary.recordedFraction(at: playbackDate)
        return Gauge(value: alert == nil ? fraction : 0) {
            Image(systemName: alert?.symbolName ?? activitySymbolName)
        } currentValueLabel: {
            Text(alert == nil ? "\(Int((fraction * 100).rounded()))" : "!")
                .font(.caption2.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel(accessibilityLabel)
    }

    private var inlineView: some View {
        Label {
            Text(alert?.title ?? activityTitle)
        } icon: {
            Image(systemName: alert?.symbolName ?? activitySymbolName)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - 값

    private var measurement: TaptionWatchMeasurementSnapshot? {
        resolvedMeasurement
    }

    private var playbackDate: Date { max(entry.date, .now) }

    private var alert: TaptionWatchAlert? {
        TaptionWatchAlertPolicy.primary(
            for: measurement,
            now: playbackDate,
            language: language
        )
    }

    private var activityTitle: String {
        if let suggestion = confirmationSuggestion {
            return language.text(
                "\(suggestion.proposedBehavior.localizedTitle(.korean)) 맞나요?",
                "Was this \(suggestion.proposedBehavior.localizedTitle(.english))?"
            )
        }
        // iPhone이 정한 지금 활동이 정본이다. 없으면 Watch 측정값을 쓴다.
        if let activity = resolvedPayload?.currentActivity {
            return activity.title(for: language)
        }
        guard let behavior = measurement?.behavior else {
            return measurement?.isRecordingRequested == false
                ? language.text("기록 꺼짐", "Recording off")
                : language.text("측정 대기", "Waiting to measure")
        }
        return behavior.localizedTitle(language)
    }

    private var nextPlan: TaptionWatchPlanItem? {
        TaptionWatchLiveItemPolicy.upcoming(resolvedPayload?.items ?? [], at: playbackDate).first
    }

    private var summary: TaptionWatchDaySummary {
        resolvedPayload?.todaySummary
            ?? TaptionWatchDaySummary(
                date: playbackDate,
                scheduledCount: 0,
                completedCount: 0,
                recordedMinutes: 0,
                activeMinutes: 0
            )
    }

    private var accessibilityLabel: String {
        if let alert { return "\(alert.title), \(alert.detail)" }
        let today = language.text("오늘 \(duration(summary.recordedMinutes))", "Today \(duration(summary.recordedMinutes))")
        return "\(activityTitle), \(today)"
    }

    private var confirmationSuggestion: TaptionWatchActivitySuggestion? {
        guard let value = resolvedPayload?.activitySuggestion,
              playbackDate.timeIntervalSince(value.endedAt) <= 2 * 3_600 else {
            return nil
        }
        return value
    }

    private var activitySymbolName: String {
        switch confirmationSuggestion?.proposedBehavior ?? measurement?.behavior {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .stairsUp, .stairsDown: "figure.stairs"
        case .elevator: "arrow.up.arrow.down"
        case .automotive: "car.fill"
        case .publicTransit: "bus.fill"
        case .subway: "tram.fill"
        case .exercise: "dumbbell.fill"
        case .brushingTeeth: "mouth.fill"
        case .eating: "fork.knife"
        case .typing: "keyboard"
        case .housework: "house.fill"
        case .showering: "shower.fill"
        case .sleep: "bed.double.fill"
        case .lying: "bed.double"
        case .sitting: "chair.fill"
        case .standing: "figure.stand"
        case .stationary, .unknown, .none: "waveform.path.ecg"
        }
    }

    private func duration(_ minutes: Int) -> String {
        if minutes < 60 { return language.text("\(minutes)분", "\(minutes) min") }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? language.text("\(hours)시간", "\(hours) hr")
            : language.text("\(hours)시간 \(remainder)분", "\(hours) hr \(remainder) min")
    }
}

private extension TaptionWatchPayload {
    static var widgetPlaceholder: Self {
        let now = Date.now
        return TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now.addingTimeInterval(-3_600),
            viewportEnd: now.addingTimeInterval(5 * 3_600),
            items: [
                TaptionWatchPlanItem(
                    id: UUID(),
                    title: AppLanguagePreference.text(
                        korean: "신제품 기획",
                        english: "New product planning"
                    ),
                    categoryID: "project",
                    startsAt: now.addingTimeInterval(45 * 60),
                    endsAt: now.addingTimeInterval(105 * 60),
                    status: "planned",
                    actualStartedAt: nil,
                    categoryName: AppLanguagePreference.text(
                        korean: "프로젝트",
                        english: "Project"
                    ),
                    categoryHex: "7B57B2"
                ),
            ],
            catStyle: "calico",
            reducesMotion: false,
            todaySummary: TaptionWatchDaySummary(
                date: now,
                scheduledCount: 5,
                completedCount: 2,
                recordedMinutes: 180,
                activeMinutes: 45
            )
        )
    }
}

private extension TaptionWatchMeasurementSnapshot {
    static var widgetPlaceholder: Self {
        let now = Date.now
        return TaptionWatchMeasurementSnapshot(
            updatedAt: now,
            source: .ambient,
            behavior: .walking,
            confidenceScore: 0.79,
            measuredAt: now.addingTimeInterval(-120),
            isRecordingRequested: true,
            isRecorderAvailable: true
        )
    }
}
