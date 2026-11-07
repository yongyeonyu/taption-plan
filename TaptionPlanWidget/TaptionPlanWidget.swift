import ActivityKit
import AppIntents
import OSLog
import SwiftUI
import TaptionPlanCore
import WidgetKit

@main
struct TaptionPlanWidgetBundle: WidgetBundle {
    init() {
        TaptionPlanSharedContainer.configure(
            provider: FixedTaptionPlanAppGroupProvider(
                identifier: TaptionPlanSharedContainer.defaultAppGroupIdentifier
            )
        )
    }

    var body: some Widget {
        TaptionScheduleWidget()
        TaptionPlanLiveActivity()
        SensorCollectionLiveActivity()
    }
}

struct TaptionScheduleEntry: TimelineEntry {
    var date: Date
    var payload: TaptionWidgetPayload
}

struct TaptionScheduleProvider: TimelineProvider {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "WidgetSync"
    )

    func placeholder(in context: Context) -> TaptionScheduleEntry {
        TaptionScheduleEntry(date: .now, payload: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (TaptionScheduleEntry) -> Void
    ) {
        UITextPack.reloadSelection()
        completion(
            TaptionScheduleEntry(
                date: .now,
                payload: context.isPreview
                    ? .placeholder
                    : groundTruthPayload()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TaptionScheduleEntry>) -> Void
    ) {
        // 앱에서 바꾼 언어를 위젯 프로세스가 오래 살아 있어도 다시 읽는다.
        UITextPack.reloadSelection()
        let now = Date.now
        let payload = groundTruthPayload(at: now)
        let horizon = now.addingTimeInterval(15 * 60)
        var refreshDates = TaptionWidgetPlaybackEngine.timelineDates(
            for: payload.items,
            from: now,
            horizon: horizon
        )
        // WidgetKit may put a widget in its low-frequency rendering mode,
        // where AnimationTimelineSchedule is evaluated only once.  Keep a
        // short explicit playback window as a fallback so the cat still
        // advances on the home screen.  The entries are limited to one walk
        // cycle; real data boundaries continue to control the long timeline.
        if payload.reducesMotion != true {
            let playbackEnd = min(
                horizon,
                now.addingTimeInterval(
                    TaptionWidgetCatWalkEngine.sequenceDuration
                )
            )
            var frame = now.addingTimeInterval(
                TaptionWidgetCatWalkEngine.defaultStepDuration
            )
            while frame <= playbackEnd {
                refreshDates.append(frame)
                frame = frame.addingTimeInterval(
                    TaptionWidgetCatWalkEngine.defaultStepDuration
                )
            }
        }
        let entries = Array(Set(refreshDates))
            .sorted()
            .map {
                TaptionScheduleEntry(
                    date: $0,
                    payload: payload
                )
            }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }

    private func groundTruthPayload(
        at date: Date = .now
    ) -> TaptionWidgetPayload {
        let payload = TaptionWidgetSharedStore.readGroundTruthPayload(
            now: date
        )
        let locationCount = payload.items.filter {
            $0.resolvedLane == .location
        }.count
        let movementCount = payload.items.filter {
            $0.resolvedLane == .movement
        }.count
        Self.logger.notice(
            "Widget ground-truth read: sourceUpdated=\(payload.sourceSnapshotUpdatedAt?.timeIntervalSince1970 ?? 0, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public), items=\(payload.items.count, privacy: .public), locations=\(locationCount, privacy: .public), movements=\(movementCount, privacy: .public), reducesMotion=\(payload.reducesMotion ?? false, privacy: .public)"
        )
        return payload
    }
}

struct TaptionScheduleWidget: Widget {
    let kind = TaptionWidgetKind.schedule

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TaptionScheduleProvider()
        ) { entry in
            TaptionScheduleWidgetView(entry: entry)
                .unredacted()
                .containerBackground(.white, for: .widget)
                .environment(
                    \.locale,
                    AppLanguagePreference.current.resolvedLanguage.locale
                )
        }
        .configurationDisplayName("Taption 시간표")
        .description("현재선 중심의 시간표에서 계획을 바로 처리합니다.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

private struct TaptionScheduleWidgetMetrics {
    let family: WidgetFamily

    var horizontalPadding: CGFloat {
        // WidgetKit's system margins are disabled below, so keep a small
        // deliberate inset inside the widget card instead of letting the
        // timeline touch the rounded edge.
        12
    }

    var verticalPadding: CGFloat {
        8
    }

    var headerHeight: CGFloat {
        switch family {
        case .systemExtraLarge: 26
        case .systemLarge: 24
        default: 20
        }
    }

    var headerBottomSpacing: CGFloat {
        switch family {
        case .systemExtraLarge: 4
        case .systemLarge: 3
        default: 2
        }
    }

    var titleFontSize: CGFloat {
        switch family {
        case .systemExtraLarge: 15
        case .systemLarge: 14
        default: 13
        }
    }

    var badgeFontSize: CGFloat {
        switch family {
        case .systemExtraLarge: 9
        case .systemLarge: 8.5
        default: 8
        }
    }

    var weatherIconSize: CGFloat {
        switch family {
        case .systemExtraLarge: 11
        case .systemLarge: 10.5
        default: 10
        }
    }

    var weatherFontSize: CGFloat {
        switch family {
        case .systemExtraLarge: 10
        case .systemLarge: 9.5
        default: 9
        }
    }

    var catWidth: CGFloat {
        switch family {
        case .systemExtraLarge: 116
        case .systemLarge: 92
        default: 74
        }
    }

    var catHeight: CGFloat {
        switch family {
        case .systemExtraLarge: 42
        case .systemLarge: 36
        default: 30
        }
    }

    var visibleRowLimit: Int {
        switch family {
        case .systemExtraLarge: 6
        case .systemLarge: 5
        default: 4
        }
    }

    var maxItemsPerLane: Int {
        switch family {
        case .systemExtraLarge: 14
        case .systemLarge: 10
        default: 6
        }
    }

    var windowDuration: TimeInterval {
        TaptionWidgetPlaybackEngine.defaultWindowDuration
    }
}

private struct TaptionScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TaptionScheduleEntry
    @State private var renderPayload: TaptionWidgetPayload

    init(entry: TaptionScheduleEntry) {
        self.entry = entry

        // Decode the app-group snapshot once when the widget view is created.
        // Doing this on every animation tick blocks the main actor and makes
        // the cat appear frozen when sensor data is large.
        let groundTruth = TaptionWidgetSharedStore.readGroundTruthPayload(
            now: .now
        )
        _renderPayload = State(
            initialValue: TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: entry.payload
            )
        )
    }

    var body: some View {
        // Use a periodic schedule in addition to the explicit provider frames.
        // AnimationTimelineSchedule is allowed to be reduced to a single
        // frame by WidgetKit when the widget is rendered remotely; periodic
        // playback keeps the pose and position changing in that mode too.
        TimelineView(
            .periodic(
                from: entry.date,
                by: playbackInterval
            )
        ) { context in
            let payload = renderPayload
            let playbackDate = max(entry.date, context.date)
            let metrics = TaptionScheduleWidgetMetrics(family: family)
            let trackDate = timelineCenterDate(playbackDate: playbackDate)
            let trackDuration = timelineWindowDuration(metrics: metrics)
            if payload.hidesSensitiveContent {
                lockedWidgetState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header(
                        at: playbackDate,
                        payload: payload,
                        metrics: metrics,
                        catStyle: payload.catStyle,
                        catActivity: catActivity(at: playbackDate, payload: payload),
                        reducesMotion: payload.reducesMotion ?? false,
                        walkPose: TaptionWidgetCatWalkEngine.pose(
                            at: playbackDate,
                            preferredAction: preferredCatAction(
                                at: playbackDate,
                                payload: payload
                            )
                        )
                    )

                    if payload.items.isEmpty {
                        emptyWidgetState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PrototypeWidgetTrack(
                            payload: payload,
                            date: trackDate,
                            visibleRowLimit: metrics.visibleRowLimit,
                            maxItemsPerLane: metrics.maxItemsPerLane,
                            windowDuration: trackDuration,
                            resolutionLabel: TaptionWidgetPlaybackEngine.defaultResolutionLabel
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, TaptionScheduleWidgetMetrics(family: family).horizontalPadding)
        .padding(.vertical, TaptionScheduleWidgetMetrics(family: family).verticalPadding)
        .onChange(of: entry.payload) { _, newPayload in
            renderPayload = TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: newPayload,
                cached: renderPayload
            )
        }
        .widgetURL(deepLinkURL(payload: renderPayload, at: .now))
    }

    private var lockedWidgetState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
            Text(AppLanguagePreference.text("앱을 열어 잠금을 해제하세요", "Open the app to unlock"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(
            WidgetPalette.automaticFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var emptyWidgetState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
            Text(AppLanguagePreference.text("앱을 열어 오늘 기록을 동기화하세요", "Open the app to sync today's records"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)
                .multilineTextAlignment(.center)
            Text(AppLanguagePreference.text("일정 · 위치 · 이동 · 활동이 여기에 표시됩니다", "Plans, places, trips and activity appear here"))
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(
            WidgetPalette.automaticFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func header(
        at date: Date,
        payload: TaptionWidgetPayload,
        metrics: TaptionScheduleWidgetMetrics,
        catStyle: String,
        catActivity: TaptionWidgetItem?,
        reducesMotion: Bool,
        walkPose: TaptionWidgetCatWalkPose
    ) -> some View {
        let needsLocationPermission = payload.locationTrackingEnabled == true
            && !["authorized", "limited"].contains(
                payload.locationPermissionState ?? ""
            )
        return HStack(spacing: 0) {
            Text("지금의 시간표")
                .font(.system(size: metrics.titleFontSize, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)

            Text(statusLabel(at: date, payload: payload))
                .font(.system(size: metrics.badgeFontSize, weight: .bold))
                .foregroundStyle(WidgetPalette.focusInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(WidgetPalette.focusFill, in: Capsule())
                .padding(.leading, 5)

            Link(destination: URL(string: "taptionplan://cats")!) {
                WidgetWalkingCat(
                    style: catStyle,
                    activity: catActivity,
                    reducesMotion: reducesMotion,
                    pose: walkPose
                )
                .frame(width: metrics.catWidth, height: metrics.catHeight)
            }
            .buttonStyle(.plain)
            .padding(.leading, 5)

            if needsLocationPermission {
                Button(intent: TaptionWidgetLocationGuidanceIntent()) {
                    trackingIcon(
                        "exclamationmark.triangle.fill",
                        color: WidgetPalette.focusInk,
                        metrics: metrics
                    )
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .accessibilityLabel(AppLanguagePreference.text("GPS 트래킹 권한 안내 열기", "Open GPS tracking permission guidance"))
            } else {
                Button(
                    intent: TaptionWidgetLocationTrackingIntent(
                        enabled: !(payload.locationTrackingEnabled ?? false)
                    )
                ) {
                    trackingIcon(
                        payload.locationTrackingEnabled == true
                            ? "location.fill"
                            : "location.slash",
                        color: payload.locationTrackingEnabled == true
                            ? WidgetPalette.weather
                            : WidgetPalette.secondary,
                        metrics: metrics
                    )
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .accessibilityLabel(
                    payload.locationTrackingEnabled == true
                        ? "이동 위치 트래킹 끄기"
                        : "이동 위치 트래킹 켜기"
                )
            }

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                Image(systemName: weatherSymbol(payload: payload))
                    .font(.system(size: metrics.weatherIconSize, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        weatherSymbolColor(payload: payload, component: .primary),
                        weatherSymbolColor(payload: payload, component: .secondary)
                    )
                Text(weatherAndTimeLabel(at: date, payload: payload))
                    .font(.system(size: metrics.weatherFontSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(
                        weatherSymbolColor(payload: payload, component: .primary)
                    )
            }
        }
        .frame(height: metrics.headerHeight)
        .padding(.bottom, metrics.headerBottomSpacing)
    }

    private func trackingIcon(
        _ systemName: String,
        color: Color,
        metrics: TaptionScheduleWidgetMetrics
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: metrics.weatherIconSize, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(WidgetPalette.automaticFill, in: Circle())
    }

    private func visibleItems(
        in payload: TaptionWidgetPayload
    ) -> [TaptionWidgetItem] {
        payload.items
            .filter { !$0.isCompleted }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func currentItem(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> TaptionWidgetItem? {
        visibleItems(in: payload).first {
            $0.startsAt <= date && date < $0.endsAt
        }
    }

    private func actionItem(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> TaptionWidgetItem? {
        let actionableItems = visibleItems(in: payload).filter {
            $0.resolvedLane == .action && !$0.isFixed
        }
        return actionableItems.first {
            $0.startsAt <= date && date < $0.endsAt
        }
            ?? actionableItems.first(where: { date < $0.startsAt })
            ?? actionableItems.last
    }

    private func catActivity(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> TaptionWidgetItem? {
        visibleItems(in: payload).first(where: {
            $0.resolvedLane == .action
                && !$0.isFixed
                && $0.startsAt <= date
                && date < $0.endsAt
        })
    }

    private func preferredCatAction(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> TaptionWidgetCatAction? {
        guard let item = catActivity(at: date, payload: payload) else {
            return nil
        }
        return TaptionWidgetCatActionSelector.preferredAction(
            categoryID: item.categoryID,
            title: item.title
        )
    }

    private func statusLabel(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> String {
        if TaptionWidgetPlaybackEngine.activeItems(
            in: .action,
            from: payload.items,
            at: date
        ).isEmpty == false {
            return AppLanguagePreference.text("집중 중", "Focusing")
        }
        return currentItem(at: date, payload: payload) == nil
            ? AppLanguagePreference.text("대기", "Waiting")
            : AppLanguagePreference.text("기록 중", "Recording")
    }

    private func weatherSymbol(payload: TaptionWidgetPayload) -> String {
        payload.weatherSymbolName ?? "clock"
    }

    private func weatherSymbolColor(
        payload: TaptionWidgetPayload,
        component: WeatherSymbolPaletteComponent
    ) -> Color {
        let palette = WeatherSymbolKind(
            symbolName: weatherSymbol(payload: payload)
        ).palette
        let color = component == .primary ? palette.primary : palette.secondary
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private func weatherAndTimeLabel(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let temperature = payload.temperatureCelsius else {
            return time
        }
        return "\(AppRegion.current.temperature(celsius: temperature))° · \(time)"
    }

    private func deepLinkURL(
        payload: TaptionWidgetPayload,
        at date: Date
    ) -> URL? {
        let linkDate = timelineCenterDate(playbackDate: date)
        guard let item = actionItem(at: linkDate, payload: payload) else {
            return URL(string: "taptionplan://today")
        }
        return URL(string: "taptionplan://plan/\(item.id.uuidString)")
    }

    private func timelineCenterDate(
        playbackDate: Date
    ) -> Date {
        playbackDate
    }

    private func timelineWindowDuration(
        metrics: TaptionScheduleWidgetMetrics
    ) -> TimeInterval {
        metrics.windowDuration
    }

    private var playbackInterval: TimeInterval {
        // Use the same supported periodic clock for the chart and the cat.
        // A nested TimelineView can be archived at its initial frame inside a
        // widget, leaving the cat apparently stopped.
        TaptionWidgetCatWalkEngine.defaultStepDuration
    }
}

private struct PrototypeWidgetTrack: View {
    let payload: TaptionWidgetPayload
    let date: Date
    let visibleRowLimit: Int
    let maxItemsPerLane: Int
    let windowDuration: TimeInterval
    let resolutionLabel: String?

    var body: some View {
        GeometryReader { proxy in
            let lanes = TaptionWidgetPlaybackEngine.lanes(
                for: payload.items,
                at: date,
                windowDuration: windowDuration
            )
            // Keep the table flush to the widget edge.  The old 62pt label
            // gutter plus outer widget padding hid the right side of the
            // six-hour grid on compact families.
            let labelWidth: CGFloat = 56
            let axisHeight: CGFloat = 15
            let trackWidth = max(1, proxy.size.width - labelWidth)
            let viewportHeight = max(1, proxy.size.height - axisHeight)
            let visibleRowCount = max(
                1,
                min(
                    visibleRowLimit,
                    lanes.count
                )
            )
            // Keep the lanes compact.  The previous implementation expanded
            // every row to fill the entire viewport, which made a few items
            // look vertically disconnected and pushed the chart away from
            // the header.  A capped row still scrolls when there are more
            // lanes than fit in the widget.
            let idealRowHeight = viewportHeight / CGFloat(visibleRowCount)
            let rowHeight = min(
                idealRowHeight,
                visibleRowLimit >= 6 ? 28 : 30
            )
            let contentHeight = rowHeight * CGFloat(lanes.count)
            let scrollProgress = TaptionWidgetAutoScrollEngine.progress(
                at: date,
                rowCount: lanes.count,
                visibleRows: visibleRowCount,
                reducesMotion: payload.reducesMotion ?? false
            )
            let scrollOffset = CGFloat(
                TaptionWidgetAutoScrollEngine.offset(
                    at: date,
                    contentHeight: Double(contentHeight),
                    viewportHeight: Double(viewportHeight),
                    rowCount: lanes.count,
                    visibleRows: visibleRowCount,
                    reducesMotion: payload.reducesMotion ?? false
                )
            )
            let nowX = labelWidth + trackWidth / 2

            ZStack(alignment: .topLeading) {
                axisLabels(
                    labelWidth: labelWidth,
                    trackWidth: trackWidth
                )

                ZStack(alignment: .topLeading) {
                    ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                        let y = CGFloat(index) * rowHeight
                        laneBackground(
                            lane: lane,
                            width: proxy.size.width,
                            height: rowHeight
                        )
                        .offset(y: y)

                        laneLabel(lane)
                            .frame(width: labelWidth - 4, height: rowHeight)
                            .offset(x: 2, y: y)
                    }

                    ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                        let y = CGFloat(index) * rowHeight
                        ForEach(trackItems(in: lane).prefix(maxItemsPerLane)) { item in
                            itemBar(
                                item,
                                lane: lane,
                                trackWidth: trackWidth,
                                rowHeight: rowHeight
                            )
                            .offset(
                                    x: labelWidth
                                    + trackWidth * fraction(item.startsAt),
                                    y: y
                                    + max(
                                        1,
                                        (rowHeight - barHeight(rowHeight)) / 2
                                    )
                            )
                        }
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: contentHeight,
                    alignment: .topLeading
                )
                .offset(y: -scrollOffset)
                .frame(
                    width: proxy.size.width,
                    height: viewportHeight,
                    alignment: .top
                )
                .clipped()
                .offset(y: axisHeight)

                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    Rectangle()
                        .fill(WidgetPalette.line.opacity(fraction == 0.5 ? 0.9 : 0.55))
                        .frame(width: 0.5, height: viewportHeight)
                        .offset(
                            x: labelWidth + trackWidth * fraction,
                            y: axisHeight
                        )
                }

                Rectangle()
                    .fill(WidgetPalette.now)
                    .frame(
                        width: 1.5,
                        height: viewportHeight
                    )
                    .offset(x: nowX - 0.75, y: axisHeight)

                Circle()
                    .fill(WidgetPalette.now)
                    .frame(width: 6, height: 6)
                    .offset(x: nowX - 3, y: axisHeight - 3)

                if contentHeight > viewportHeight {
                    Capsule()
                        .fill(WidgetPalette.line.opacity(0.65))
                        .frame(width: 2, height: 15)
                        .overlay(alignment: .top) {
                            Circle()
                                .fill(WidgetPalette.secondary.opacity(0.85))
                                .frame(width: 3.5, height: 3.5)
                                .offset(y: 11.5 * scrollProgress)
                        }
                        .offset(
                            x: proxy.size.width - 2.5,
                            y: axisHeight + 4
                        )
                }
            }
            .clipped()
        }
    }

    private var windowStart: Date {
        date.addingTimeInterval(-windowDuration / 2)
    }

    private var windowEnd: Date {
        date.addingTimeInterval(windowDuration / 2)
    }

    private func trackItems(
        in lane: TaptionWidgetLane
    ) -> [TaptionWidgetItem] {
        TaptionWidgetPlaybackEngine.visibleItems(
            in: lane,
            from: payload.items,
            at: date,
            windowDuration: windowDuration
        )
    }

    private func axisLabels(
        labelWidth: CGFloat,
        trackWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text(windowDurationLabel)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: labelWidth - 4, alignment: .leading)
                .offset(x: 2)
            Text(windowStart.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .offset(x: labelWidth)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WidgetPalette.now)
                .frame(width: 54)
                .offset(x: labelWidth + trackWidth / 2 - 27)
            Text(windowEnd.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: 45, alignment: .trailing)
                .offset(x: labelWidth + trackWidth - 45)
        }
    }

    private var windowDurationLabel: String {
        if let resolutionLabel {
            return resolutionLabel
        }
        let hours = Int(windowDuration / 3_600)
        guard hours < 24 else { return "24시간" }
        return "\(max(1, hours))시간"
    }

    private func laneBackground(
        lane: TaptionWidgetLane,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Rectangle()
            .fill(
                lane == .action
                    ? Color.white
                    : WidgetPalette.automaticFill
            )
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(WidgetPalette.line)
                    .frame(height: 0.5)
            }
    }

    private func laneLabel(_ lane: TaptionWidgetLane) -> some View {
        Label(lane.localizedTitle, systemImage: lane.systemImage)
            .font(.system(size: 9.2, weight: .bold))
            .foregroundStyle(WidgetPalette.ink.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func itemBar(
        _ item: TaptionWidgetItem,
        lane: TaptionWidgetLane,
        trackWidth: CGFloat,
        rowHeight: CGFloat
    ) -> some View {
        let start = fraction(item.startsAt)
        let end = fraction(item.endsAt)
        let width = max(4, trackWidth * max(0.012, end - start))
        let active = item.startsAt <= date && date < item.endsAt
        return RoundedRectangle(cornerRadius: 5)
            .fill(categoryColor(item, lane: lane).opacity(active ? 1 : 0.86))
            .frame(width: width, height: barHeight(rowHeight))
            .overlay(alignment: .leading) {
                if width >= 34 {
                    Text(item.title)
                        .font(.system(size: 9, weight: active ? .bold : .semibold))
                        .foregroundStyle(WidgetPalette.ink.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(WidgetPalette.ink.opacity(0.28), lineWidth: 0.6)
                }
            }
    }

    private func barHeight(_ rowHeight: CGFloat) -> CGFloat {
        // Keep bars nearly flush inside each lane while retaining a 1–2pt
        // separator so adjacent segments remain visually distinct.
        min(22, max(14, rowHeight - 3))
    }

    private func fraction(_ value: Date) -> CGFloat {
        let duration = windowEnd.timeIntervalSince(windowStart)
        return CGFloat(
            min(
                1,
                max(
                    0,
                    value.timeIntervalSince(windowStart) / duration
                )
            )
        )
    }

    private func categoryColor(
        _ item: TaptionWidgetItem,
        lane: TaptionWidgetLane
    ) -> Color {
        if let hex = item.categoryHex {
            return Color(widgetHex: hex)
        }
        switch lane {
        case .schedule:
            return Color(red: 0.78, green: 0.80, blue: 0.83)
        case .location:
            return Color(red: 0.63, green: 0.83, blue: 0.92)
        case .movement:
            return Color(red: 0.82, green: 0.68, blue: 0.46)
        case .sleep:
            return Color(red: 0.79, green: 0.84, blue: 0.90)
        case .activity:
            return Color(red: 0.49, green: 0.68, blue: 0.51)
        case .appUsage:
            return Color(red: 0.55, green: 0.48, blue: 0.72)
        case .action:
            break
        }
        return switch item.categoryID {
        case "exercise": Color(red: 0.996, green: 0.835, blue: 0.812)
        case "activity": Color(red: 0.784, green: 0.875, blue: 0.765)
        case "study": Color(red: 0.827, green: 0.780, blue: 0.902)
        case "hobby": Color(red: 0.769, green: 0.914, blue: 0.855)
        case "sleep": Color(red: 0.851, green: 0.867, blue: 0.918)
        case "movement": Color(red: 0.910, green: 0.827, blue: 0.702)
        case "location": Color(red: 0.847, green: 0.910, blue: 0.949)
        case "travel": Color(red: 0.945, green: 0.710, blue: 0.596)
        case "health": Color(red: 0.784, green: 0.875, blue: 0.765)
        case "photo": Color(red: 0.906, green: 0.843, blue: 0.933)
        default: Color(red: 0.745, green: 0.855, blue: 0.890)
        }
    }
}

private struct WidgetWalkingCat: View {
    let style: String
    let activity: TaptionWidgetItem?
    let reducesMotion: Bool
    let pose: TaptionWidgetCatWalkPose

    var body: some View {
        GeometryReader { proxy in
            let isAnimating = !reducesMotion
            let isMoving = isAnimating && pose.action.movesAcrossTrack
            let sharedPose = TaptionCatAnimationEngine.pose(
                from: (reducesMotion ? TaptionWidgetCatAction.sitting : pose.action).rawValue,
                progress: reducesMotion ? 0.5 : pose.progress,
                phase: isAnimating ? pose.legPhase : 0,
                facesLeft: pose.facesLeft && isAnimating,
                tailSwing: isAnimating ? pose.tailSwing : 0,
                headTiltDegrees: isAnimating ? pose.headTiltDegrees : 0,
                legSwing: isAnimating ? pose.legSwing : 0,
                idle: isAnimating ? pose.idle : .still
            )

            ZStack(alignment: .topLeading) {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(
                                WidgetPalette.secondary.opacity(
                                    index % 2 == pose.legPhase % 2
                                        ? 0.20
                                        : 0.08
                                )
                            )
                            .frame(width: 2.2, height: 1.5)
                    }
                }
                .offset(x: 5, y: 19)
                .opacity(isMoving ? 1 : 0)

                TaptionCatAnimationView(
                    style: style,
                    pose: sharedPose,
                    reducesMotion: reducesMotion,
                    scene: scene
                )
            }
        }
        .accessibilityLabel(
            "\(catName) 고양이가 \(actionLabel)"
        )
    }

    private var scene: TaptionHwarangPose? {
        activity.flatMap {
            TaptionHwarangPose.widgetScene(
                style: style,
                categoryID: $0.categoryID,
                title: $0.title,
                action: pose.action,
                reducesMotion: reducesMotion
            )
        }
    }

    private var catName: String {
        switch style {
        case "white": "화랑이"
        case "mackerel": "윤복이"
        case "black": "검정"
        case "gray": "회색"
        case "cheese": "치즈"
        case "cow": "젖소무늬"
        default: "춘향이"
        }
    }

    private var actionLabel: String {
        if scene != nil, let activity { return "\(activity.title) 중" }
        return switch reducesMotion ? .sitting : pose.action {
        case .walking: "걷는 중"
        case .running: "달리는 중"
        case .sitting: "앉아 있는 중"
        case .sleeping: "자는 중"
        case .grooming: "그루밍하는 중"
        case .eating: "밥 먹는 중"
        case .startled: "놀란 상태"
        case .ballPlay: "공을 잡고 노는 중"
        case .fishingPlay: "낚싯대 장난감으로 노는 중"
        case .stretching: "기지개를 켜는 중"
        case .kneading: "꾹꾹이를 하는 중"
        case .yawning: "하품하는 중"
        }
    }
}

enum WidgetPalette {
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.89)
    static let automaticFill = Color(red: 0.935, green: 0.935, blue: 0.945)
    static let focusFill = Color(red: 1.00, green: 0.95, blue: 0.85)
    static let focusInk = Color(red: 0.57, green: 0.38, blue: 0.08)
    static let weather = Color(red: 0.31, green: 0.47, blue: 0.59)
    static let now = Color(red: 1.00, green: 0.23, blue: 0.19)
}

struct TaptionWidgetActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Taption 계획 처리"
    static let description = IntentDescription("위젯에서 계획을 완료하거나 이동합니다.")
    static let openAppWhenRun = false

    @Parameter(title: "계획 ID")
    var planID: String

    @Parameter(title: "동작")
    var actionRawValue: String

    init() {
        planID = ""
        actionRawValue = TaptionWidgetCommandKind.complete.rawValue
    }

    init(planID: String, action: TaptionWidgetCommandKind) {
        self.planID = planID
        actionRawValue = action.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: planID),
              let action = TaptionWidgetCommandKind(rawValue: actionRawValue) else {
            return .result()
        }

        var command = TaptionWidgetCommand(planID: id, kind: action)
        var refreshedPayload: TaptionWidgetPayload?
        do {
            let repository = try TaptionStoreRepository.appGroup()
            let source = try await repository.load()
            let updated = try TaptionWidgetCommandEngine.apply(
                command,
                to: source
            )
            try await repository.save(updated)
            refreshedPayload = TaptionWidgetPayloadFactory.make(
                from: updated,
                hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
            )
            command.appliedToSharedRepository = true
        } catch {
            command.appliedToSharedRepository = false
        }

        if let refreshedPayload {
            try? TaptionWidgetSharedStore.writePayload(refreshedPayload)
        }
        try TaptionWidgetSharedStore.appendCommand(command)
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

}

struct TaptionWidgetLocationTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "이동 위치 트래킹"
    static let description = IntentDescription("아이폰의 이동 위치 기록을 켜거나 끕니다.")
    static let openAppWhenRun = true

    @Parameter(title: "켜기")
    var enabled: Bool

    init() {
        enabled = false
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func perform() async throws -> some IntentResult {
        TaptionLocationTrackingRequestStore.write(enabled)
        if let repository = try? TaptionStoreRepository.appGroup(),
           var snapshot = try? await repository.load() {
            snapshot.settings.locationEnabled = enabled
            if !enabled {
                snapshot.settings.backgroundPreciseLocationEnabled = false
            }
            snapshot.updatedAt = .now
            if (try? await repository.save(snapshot)) != nil {
                let payload = TaptionWidgetPayloadFactory.make(
                    from: snapshot,
                    hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
                )
                try? TaptionWidgetSharedStore.writePayload(payload)
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        return .result()
    }
}

struct TaptionWidgetLocationGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "GPS 트래킹 권한 안내"
    static let description = IntentDescription("아이폰에서 위치 권한 안내를 다시 엽니다.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        TaptionLocationTrackingRequestStore.requestGuidance()
        return .result()
    }
}

extension Color {
    init(widgetHex value: String) {
        let normalized = value
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&number) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        switch normalized.count {
        case 3:
            red = ((number >> 8) & 0xF) * 17
            green = ((number >> 4) & 0xF) * 17
            blue = (number & 0xF) * 17
        case 8:
            red = (number >> 16) & 0xFF
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        default:
            red = (number >> 16) & 0xFF
            green = (number >> 8) & 0xFF
            blue = number & 0xFF
        }
        self.init(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
