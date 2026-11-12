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
        TaptionWatchNextPlanWidget()
        TaptionWatchDayWidget()
    }
}

// MARK: - 타임라인

private struct TaptionWatchWidgetEntry: TimelineEntry {
    let date: Date
    let payload: TaptionWatchPayload?
    let measurement: TaptionWatchMeasurementSnapshot?
    var relevance: TimelineEntryRelevance?
}

/// 세 위젯이 같은 저장값을 읽는다. 경과 시간·남은 시간 글자는 시스템이 스스로 갱신하므로
/// 항목은 15분 격자와 일정 경계에만 둔다. 새 값이 오면 워치 앱이 타임라인을 다시 부른다.
private struct TaptionWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaptionWatchWidgetEntry {
        TaptionWatchWidgetEntry(date: .now, payload: .widgetPlaceholder, measurement: .widgetPlaceholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (TaptionWatchWidgetEntry) -> Void
    ) {
        UITextPack.reloadSelection()
        completion(
            context.isPreview
                ? placeholder(in: context)
                : TaptionWatchWidgetEntry(
                    date: .now,
                    payload: TaptionWatchWidgetStore.read(),
                    measurement: TaptionWatchMeasurementStore.read()
                )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TaptionWatchWidgetEntry>) -> Void
    ) {
        // 워치 앱이 iPhone 선택을 앱 그룹에 남긴다. 위젯 프로세스가 오래 살아 있어도 그 값을 다시 읽는다.
        UITextPack.reloadSelection()
        let now = Date.now
        let payload = TaptionWatchWidgetStore.read()
        let measurement = TaptionWatchMeasurementStore.read()
        // 항목이 없는 타임라인은 WidgetKit이 갱신을 멈추게 만든다. 격자에는 항상 `now`가 들어 있다.
        let dates = TaptionWatchFacePolicy.timelineDates(now: now, payload: payload)
        let entries = zip(dates, dates.dropFirst() + [now.addingTimeInterval(3_600)]).map { date, next in
            let hasAlert = TaptionWatchAlertPolicy.primary(for: measurement, now: date) != nil
            return TaptionWatchWidgetEntry(
                date: date,
                payload: payload,
                measurement: measurement,
                relevance: TimelineEntryRelevance(
                    score: TaptionWatchFacePolicy.relevanceScore(payload: payload, hasAlert: hasAlert, at: date),
                    duration: max(60, next.timeIntervalSince(date))
                )
            )
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3_600))))
    }
}

// MARK: - 위젯 셋

private struct TaptionWatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TaptionWatchWidgetKind.status, provider: TaptionWatchWidgetProvider()) {
            TaptionWatchStatusView(face: TaptionWatchFace(entry: $0))
        }
        .configurationDisplayName(
            AppLanguagePreference.text(korean: "BOKKI 오늘", english: "BOKKI Today")
        )
        .description(
            AppLanguagePreference.text(
                korean: "지금 활동과 다음 일정, 오늘 기록을 표시합니다.",
                english: "Shows your current activity, next plan, and today's record."
            )
        )
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct TaptionWatchNextPlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TaptionWatchWidgetKind.nextPlan, provider: TaptionWatchWidgetProvider()) {
            TaptionWatchNextPlanView(face: TaptionWatchFace(entry: $0))
        }
        .configurationDisplayName(
            AppLanguagePreference.text(korean: "BOKKI 다음 일정", english: "BOKKI Next Plan")
        )
        .description(
            AppLanguagePreference.text(
                korean: "다음 일정과 시작까지 남은 시간을 표시합니다.",
                english: "Shows your next plan and the time left until it starts."
            )
        )
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct TaptionWatchDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TaptionWatchWidgetKind.day, provider: TaptionWatchWidgetProvider()) {
            TaptionWatchDayView(face: TaptionWatchFace(entry: $0))
        }
        .configurationDisplayName(
            AppLanguagePreference.text(korean: "BOKKI 하루", english: "BOKKI Day")
        )
        .description(
            AppLanguagePreference.text(
                korean: "오늘 기록한 시간을 분류별로 표시합니다.",
                english: "Shows today's recorded time by category."
            )
        )
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - 표시 값

/// 시계 페이스의 색. 값은 `TaptionWatchFacePolicy`가 정한다.
enum TaptionWatchFaceStyle {
    static func background(categoryID: String) -> Color {
        Color(TaptionWatchFacePolicy.background(categoryID: categoryID))
    }

    static func color(hex: String?) -> Color? {
        TaptionWatchFacePolicy.rgb(hex: hex).map(Color.init)
    }
}

extension Color {
    init(_ rgb: TaptionWatchFacePolicy.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// 한 항목을 그릴 때 쓰는 값. 저장값은 한 번만 읽어 세 위젯 화면이 같이 쓴다.
private struct TaptionWatchFace {
    let date: Date
    let payload: TaptionWatchPayload?
    let measurement: TaptionWatchMeasurementSnapshot?
    let language: AppLanguagePreference.ResolvedLanguage

    init(entry: TaptionWatchWidgetEntry) {
        date = max(entry.date, .now)
        // 앱이 방금 남긴 값과 타임라인 항목에 실려 온 값 중 새것을 고른다.
        payload = Self.freshest(TaptionWatchWidgetStore.read(), entry.payload, date: \.generatedAt)
        measurement = Self.freshest(TaptionWatchMeasurementStore.read(), entry.measurement, date: \.updatedAt)
        language = AppLanguagePreference.resolve(rawValue: payload?.languagePreference)
    }

    private static func freshest<Value>(
        _ stored: Value?,
        _ entryValue: Value?,
        date: KeyPath<Value, Date>
    ) -> Value? {
        guard let stored else { return entryValue }
        guard let entryValue else { return stored }
        return stored[keyPath: date] >= entryValue[keyPath: date] ? stored : entryValue
    }

    var activity: TaptionWatchCurrentActivity? { payload?.currentActivity }
    var categoryID: String { activity?.categoryID ?? "unconfirmed" }

    var catAssetName: String {
        TaptionWatchFacePolicy.catAssetName(
            style: payload?.catStyle ?? "calico",
            categoryID: categoryID,
            poseName: activity?.poseName
        )
    }

    var alert: TaptionWatchAlert? {
        TaptionWatchAlertPolicy.primary(for: measurement, now: date, language: language)
    }

    var suggestion: TaptionWatchActivitySuggestion? {
        TaptionWatchFacePolicy.activeSuggestion(payload, at: date)
    }

    var activityTitle: String {
        if let suggestion {
            return language.text(
                "\(suggestion.proposedBehavior.localizedTitle(.korean)) 맞나요?",
                "Was this \(suggestion.proposedBehavior.localizedTitle(.english))?"
            )
        }
        // iPhone이 정한 지금 활동이 정본이다. 없으면 Watch 측정값을 쓴다.
        if let activity { return activity.title(for: language) }
        guard let behavior = measurement?.behavior else {
            return measurement?.isRecordingRequested == false
                ? language.text("기록 꺼짐", "Recording off")
                : language.text("측정 대기", "Waiting to measure")
        }
        return behavior.localizedTitle(language)
    }

    var agenda: [TaptionWatchPlanItem] {
        TaptionWatchFacePolicy.agenda(payload?.items ?? [], at: date)
    }

    var runningPlan: TaptionWatchPlanItem? { agenda.first { $0.startsAt <= date } }
    var nextPlan: TaptionWatchPlanItem? { agenda.first { $0.startsAt > date } }

    var summary: TaptionWatchDaySummary {
        payload?.todaySummary.flatMap { $0.isCurrent(at: date) ? $0 : nil }
            ?? TaptionWatchDaySummary(
                date: date, scheduledCount: 0, completedCount: 0, recordedMinutes: 0, activeMinutes: 0
            )
    }

    var statusAccessibilityLabel: String {
        if let alert { return "\(alert.title), \(alert.detail)" }
        let recorded = duration(summary.recordedMinutes)
        return "\(activityTitle), \(language.text("오늘 \(recorded)", "Today \(recorded)"))"
    }

    var symbolName: String {
        switch suggestion?.proposedBehavior ?? measurement?.behavior {
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

    func duration(_ minutes: Int) -> String {
        TaptionWatchFacePolicy.durationText(minutes, language: language)
    }
}

/// 시스템이 스스로 갱신하는 시간 글자. 타임라인 항목이 없어도 분 단위로 맞는다.
private enum TaptionWatchLiveText {
    /// "1시간 20분"처럼 `start`부터 지난 시간.
    static func elapsed(since start: Date) -> Text {
        Text(.currentDate, format: .offset(to: start, allowedFields: [.hour, .minute], maxFieldCount: 2, sign: .never))
    }

    /// "12분 후"처럼 `date`까지 남은 시간.
    static func until(_ date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.hour, .minute], maxFieldCount: 1))
    }

    /// 원형 자리에 들어가는 짧은 남은 시간.
    static func shortUntil(_ date: Date) -> Text {
        Text(.currentDate, format: .offset(to: date, allowedFields: [.hour, .minute], maxFieldCount: 1, sign: .never))
    }
}

/// 고른 고양이가 지금 활동을 한다. 단색 페이스에서도 그림 색을 지킨다.
private struct TaptionWatchCatImage: View {
    let name: String

    var body: some View {
        Image(name)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// 기록 비율·다가오는 정도를 그리는 고리.
private struct TaptionWatchRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - BOKKI 오늘

private struct TaptionWatchStatusView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let face: TaptionWatchFace

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .environment(\.locale, face.language.locale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.statusAccessibilityLabel)
    }

    private var rectangular: some View {
        HStack(spacing: 5) {
            TaptionWatchCatImage(name: face.catAssetName)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(face.activityTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .widgetAccentable()
                    Spacer(minLength: 0)
                    if face.suggestion == nil, let activity = face.activity {
                        TaptionWatchLiveText.elapsed(since: activity.startedAt)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                    }
                }
                secondLine
                    .font(.caption2)
                    .lineLimit(1)
                dayRibbon
                    .frame(height: 5)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(TaptionWatchFaceStyle.background(categoryID: face.categoryID).gradient, for: .widget)
    }

    @ViewBuilder
    private var secondLine: some View {
        if let alert = face.alert {
            Label(alert.title, systemImage: alert.symbolName)
                .fontWeight(.semibold)
        } else if let next = face.nextPlan {
            HStack(spacing: 3) {
                Text(next.startsAt, style: .time)
                    .fontWeight(.bold)
                    .monospacedDigit()
                Text(next.title)
                    .privacySensitive()
            }
        } else {
            Text(face.language.text(
                "오늘 \(face.duration(face.summary.recordedMinutes))",
                "Today \(face.duration(face.summary.recordedMinutes))"
            ))
            .foregroundStyle(.secondary)
        }
    }

    /// 하루 24시간 중 기록된 시간을 분류 색으로 쌓는다. 순서가 아니라 분류별 합이다.
    private var dayRibbon: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                ForEach(TaptionWatchFacePolicy.daySegments(face.summary), id: \.categoryID) { segment in
                    Rectangle()
                        .fill(renderingMode == .fullColor
                            ? (TaptionWatchFaceStyle.color(hex: segment.hex) ?? .white)
                            : .white)
                        .frame(width: proxy.size.width * (segment.end - segment.start))
                        .offset(x: proxy.size.width * segment.start)
                }
            }
            .clipShape(Capsule())
        }
    }

    /// 고양이를 오늘 지나간 시간 중 기록된 비율의 고리가 감싼다.
    private var circular: some View {
        ZStack {
            TaptionWatchRing(fraction: face.alert == nil ? face.summary.recordedFraction(at: face.date) : 0)
            if let alert = face.alert {
                Image(systemName: alert.symbolName)
                    .font(.body.weight(.semibold))
            } else {
                TaptionWatchCatImage(name: face.catAssetName)
                    .padding(7)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var corner: some View {
        TaptionWatchCatImage(name: face.catAssetName)
            .widgetLabel {
                if let alert = face.alert {
                    Text(alert.title)
                } else if face.suggestion == nil, let activity = face.activity {
                    Text("\(Text(face.activityTitle)) \(TaptionWatchLiveText.elapsed(since: activity.startedAt))")
                } else {
                    Text(face.activityTitle)
                }
            }
            .containerBackground(.clear, for: .widget)
    }

    private var inline: some View {
        Label {
            if let alert = face.alert {
                Text(alert.title)
            } else if face.suggestion == nil, let activity = face.activity {
                Text("\(Text(face.activityTitle)) \(TaptionWatchLiveText.elapsed(since: activity.startedAt))")
            } else {
                Text(face.activityTitle)
            }
        } icon: {
            Image(systemName: face.alert?.symbolName ?? face.symbolName)
        }
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - BOKKI 다음 일정

private struct TaptionWatchNextPlanView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let face: TaptionWatchFace

    private var emptyTitle: String {
        face.language.text("다음 일정 없음", "No upcoming plan")
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .environment(\.locale, face.language.locale)
    }

    private func tint(_ item: TaptionWatchPlanItem) -> Color {
        renderingMode == .fullColor ? (TaptionWatchFaceStyle.color(hex: item.categoryHex) ?? .white) : .white
    }

    @ViewBuilder
    private var rectangular: some View {
        if let next = face.nextPlan {
            HStack(spacing: 6) {
                Capsule()
                    .fill(tint(next))
                    .frame(width: 4)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(next.startsAt, style: .time)
                            .font(.headline.monospacedDigit())
                            .widgetAccentable()
                        Spacer(minLength: 0)
                        TaptionWatchLiveText.until(next.startsAt)
                            .font(.caption2.weight(.semibold))
                    }
                    Text(next.title)
                        .font(.caption.weight(.semibold))
                        .privacySensitive()
                    Text(detail(next))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(TaptionWatchFaceStyle.background(categoryID: next.categoryID).gradient, for: .widget)
        } else {
            HStack(spacing: 6) {
                TaptionWatchCatImage(name: face.catAssetName)
                    .frame(width: 46)
                Text(emptyTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(TaptionWatchFaceStyle.background(categoryID: face.categoryID).gradient, for: .widget)
        }
    }

    /// 지금 하는 일정이 있으면 그 이름, 없으면 분류와 길이.
    private func detail(_ next: TaptionWatchPlanItem) -> String {
        let length = face.duration(Int(next.endsAt.timeIntervalSince(next.startsAt) / 60))
        if let running = face.runningPlan {
            return face.language.text("지금 \(running.title)", "Now \(running.title)")
        }
        return [next.categoryName, length].compactMap { $0 }.joined(separator: " · ")
    }

    /// 시작 한 시간 전부터 고리가 찬다.
    private var circular: some View {
        ZStack {
            if let next = face.nextPlan {
                TaptionWatchRing(
                    fraction: TaptionWatchFacePolicy.approachFraction(startsAt: next.startsAt, now: face.date)
                )
                TaptionWatchLiveText.shortUntil(next.startsAt)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(6)
            } else {
                TaptionWatchRing(fraction: 0)
                Image(systemName: "calendar")
                    .font(.body.weight(.semibold))
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var corner: some View {
        if let next = face.nextPlan {
            Text(next.startsAt, style: .time)
                .font(.caption.weight(.semibold).monospacedDigit())
                .widgetCurvesContent()
                .widgetLabel {
                    Text(next.title).privacySensitive()
                }
                .containerBackground(.clear, for: .widget)
        } else {
            Image(systemName: "calendar")
                .widgetLabel { Text(emptyTitle) }
                .containerBackground(.clear, for: .widget)
        }
    }

    private var inline: some View {
        Label {
            if let next = face.nextPlan {
                Text("\(Text(next.startsAt, style: .time)) \(Text(next.title))")
                    .privacySensitive()
            } else {
                Text(emptyTitle)
            }
        } icon: {
            Image(systemName: "calendar")
        }
        .containerBackground(.clear, for: .widget)
    }

    private var accessibilityLabel: String {
        guard let next = face.nextPlan else { return emptyTitle }
        return "\(next.startsAt.formatted(date: .omitted, time: .shortened)), \(next.title)"
    }
}

// MARK: - BOKKI 하루

private struct TaptionWatchDayView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let face: TaptionWatchFace

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            default: rectangular
            }
        }
        .environment(\.locale, face.language.locale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func color(hex: String?, index: Int) -> Color {
        if renderingMode == .fullColor, let color = TaptionWatchFaceStyle.color(hex: hex) { return color }
        // 단색 페이스에서는 짙기로 분류를 나눈다.
        return .white.opacity(max(0.35, 1 - Double(index) * 0.22))
    }

    @ViewBuilder
    private var rectangular: some View {
        let categories = face.summary.topCategories(limit: 3)
        VStack(alignment: .leading, spacing: 2) {
            if categories.isEmpty {
                Text(face.language.text("오늘 기록 없음", "No record today"))
                    .font(.footnote.weight(.semibold))
                Text(face.activityTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(categories.enumerated()), id: \.element.categoryID) { index, category in
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(color(hex: category.hex, index: index))
                            .frame(width: 4, height: 11)
                        Text(category.title)
                            .fontWeight(index == 0 ? .bold : .regular)
                        Spacer(minLength: 2)
                        Text(face.duration(category.minutes))
                            .monospacedDigit()
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(TaptionWatchFaceStyle.background(categoryID: face.categoryID).gradient, for: .widget)
    }

    /// 24시간 고리에 분류별 시간을 이어 붙이고 가운데에 기록한 시간을 쓴다.
    private var circular: some View {
        let segments = TaptionWatchFacePolicy.daySegments(face.summary)
        return ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 4)
            ForEach(Array(segments.enumerated()), id: \.element.categoryID) { index, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(color(hex: segment.hex, index: index), lineWidth: 4)
                    .rotationEffect(.degrees(-90))
            }
            Text(String(format: "%d:%02d", face.summary.recordedMinutes / 60, face.summary.recordedMinutes % 60))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(7)
                .widgetAccentable()
        }
        .padding(2)
        .containerBackground(.clear, for: .widget)
    }

    private var accessibilityLabel: String {
        let recorded = face.duration(face.summary.recordedMinutes)
        return face.language.text("오늘 \(recorded)", "Today \(recorded)")
    }
}

// MARK: - 미리보기 값

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
                activeMinutes: 45,
                categories: [
                    TaptionWatchCategoryMinutes(
                        categoryID: "work",
                        title: AppLanguagePreference.text(korean: "업무", english: "Work"),
                        hex: "5B9BD5",
                        minutes: 120
                    ),
                    TaptionWatchCategoryMinutes(
                        categoryID: "movement",
                        title: AppLanguagePreference.text(korean: "이동", english: "Movement"),
                        hex: "E08A3C",
                        minutes: 60
                    ),
                ]
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
