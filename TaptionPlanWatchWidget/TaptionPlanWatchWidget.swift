import SwiftUI
import WidgetKit

@main
struct TaptionPlanWatchWidgetBundle: WidgetBundle {
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
        .configurationDisplayName("Taption 측정")
        .description("지금 감지된 활동과 오늘 활동 요약을 표시합니다.")
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
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            rectangularView
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: sourceSymbolName)
                    .font(.system(size: 9, weight: .bold))
                Text(sourceTitle)
                Spacer(minLength: 2)
                Text(freshnessText)
                    .monospacedDigit()
            }
            .font(.system(size: 10))

            // 행동 이름은 19개짜리 고정 목록에서 온다. 계획 제목과 달리
            // 사용자가 쓴 글이 아니라 가려도 얻는 것이 없다.
            Text(activityTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let alert {
                HStack(spacing: 3) {
                    Image(systemName: alert.symbolName)
                    Text(alert.title)
                        .lineLimit(1)
                    Spacer(minLength: 1)
                }
                .font(.system(size: 10, weight: .semibold))
            } else if let reminder = nextReminder {
                HStack(spacing: 3) {
                    Image(systemName: "alarm.fill")
                    Text(reminder.startsAt, style: .time)
                        .monospacedDigit()
                    Text(reminder.title)
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 1)
                }
                .font(.system(size: 10, weight: .semibold))
            } else {
                Text(confidenceText)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Label(
                    duration(summary.recordedMinutes),
                    systemImage: "waveform"
                )
                Label(
                    duration(summary.activeMinutes),
                    systemImage: "figure.run"
                )
                Spacer(minLength: 1)
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .widgetAccentable()
        .accessibilityLabel(accessibilityLabel)
    }

    private var circularView: some View {
        Gauge(value: alert == nil ? confidence : 0) {
            Image(systemName: alert?.symbolName ?? activitySymbolName)
        } currentValueLabel: {
            Text(alert == nil ? "\(Int((confidence * 100).rounded()))" : "!")
                .font(.caption2.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel(accessibilityLabel)
    }

    private var inlineView: some View {
        Label {
            if let alert {
                Text(alert.title)
            } else if measurement?.behavior != nil {
                Text("\(activityTitle) · \(confidenceText)")
            } else {
                Text(sourceTitle)
            }
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
        TaptionWatchAlertPolicy.primary(for: measurement, now: playbackDate)
    }

    private var sourceTitle: String {
        if confirmationSuggestion != nil { return "확인 요청" }
        return measurement?.source.title ?? "측정 대기"
    }

    private var sourceSymbolName: String {
        switch measurement?.source ?? .idle {
        case .workout: "figure.run.circle.fill"
        case .ambient: "waveform.path.ecg"
        case .idle: "pause.circle"
        }
    }

    private var activityTitle: String {
        if let suggestion = confirmationSuggestion {
            return "\(suggestion.proposedBehavior.title) 맞나요?"
        }
        guard let behavior = measurement?.behavior else {
            return measurement?.isRecordingRequested == false
                ? "기록 꺼짐"
                : "측정 대기"
        }
        return behavior.title
    }

    private var confidence: Double {
        min(1, max(0, confirmationSuggestion?.confidenceScore
            ?? measurement?.confidenceScore ?? 0))
    }

    private var confidenceText: String {
        if confirmationSuggestion != nil { return "Watch에서 확인" }
        guard measurement?.behavior != nil else {
            return "손목 움직임을 모으는 중"
        }
        return "신뢰도 \(Int((confidence * 100).rounded()))%"
    }

    private var freshnessText: String {
        guard let measuredAt = measurement?.measuredAt else { return "—" }
        let seconds = Int(max(0, playbackDate.timeIntervalSince(measuredAt)))
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        return "\(seconds / 3_600)시간 전"
    }

    /// 곧 울릴 계획 알림. iPhone이 예약한 알림이 워치로 전달되기 전에도
    /// "다음에 무엇이 시작되는지"는 여기서 볼 수 있어야 한다.
    private var nextReminder: TaptionWatchPlanItem? {
        TaptionWatchLiveItemPolicy
            .upcoming(resolvedPayload?.items ?? [], at: playbackDate)
            .first {
                $0.startsAt.timeIntervalSince(playbackDate)
                    <= Self.reminderHorizon
            }
    }

    /// 이만큼 앞의 계획만 알림 줄에 올린다. 더 먼 일정은 iPhone이 보여준다.
    private static let reminderHorizon: TimeInterval = 2 * 3_600

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
        guard measurement?.behavior != nil else { return sourceTitle }
        return "\(activityTitle), \(confidenceText), \(freshnessText)"
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
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)시간" : "\(hours)시간 \(remainder)분"
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
                    title: "신제품 기획",
                    categoryID: "project",
                    startsAt: now.addingTimeInterval(45 * 60),
                    endsAt: now.addingTimeInterval(105 * 60),
                    status: "planned",
                    actualStartedAt: nil,
                    categoryName: "프로젝트",
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
