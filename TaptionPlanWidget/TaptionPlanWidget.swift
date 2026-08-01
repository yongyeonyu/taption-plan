import ActivityKit
import AppIntents
import OSLog
import SwiftUI
import WidgetKit

@main
struct TaptionPlanWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaptionScheduleWidget()
        TaptionPlanLiveActivity()
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
        let now = Date.now
        let payload = groundTruthPayload(at: now)
        let horizon = now.addingTimeInterval(15 * 60)
        var refreshDates = TaptionWidgetPlaybackEngine.timelineDates(
            for: payload.items,
            from: now,
            horizon: horizon
        )
        if payload.reducesMotion != true {
            refreshDates.append(
                contentsOf: (1...60).map {
                    now.addingTimeInterval(
                        Double($0) * TaptionWidgetCatWalkEngine.defaultStepDuration
                    )
                }
            )
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
            "Widget ground-truth read: fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public), locations=\(locationCount, privacy: .public), movements=\(movementCount, privacy: .public)"
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
        switch family {
        case .systemExtraLarge: 18
        case .systemLarge: 15
        default: 14
        }
    }

    var verticalPadding: CGFloat {
        switch family {
        case .systemExtraLarge: 16
        case .systemLarge: 14
        default: 12
        }
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
        case .systemExtraLarge: 14
        case .systemLarge: 12
        default: 10
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
        case .systemExtraLarge: 36
        case .systemLarge: 31
        default: 25
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

    var body: some View {
        TimelineView(
            .periodic(
                from: entry.date,
                by: playbackInterval
            )
        ) { context in
            let payload = freshestPayload
            let playbackDate = max(entry.date, context.date)
            let metrics = TaptionScheduleWidgetMetrics(family: family)
            let trackDate = timelineCenterDate(playbackDate: playbackDate)
            let trackDuration = timelineWindowDuration(metrics: metrics)
            VStack(spacing: 0) {
                header(
                    at: playbackDate,
                    payload: payload,
                    metrics: metrics,
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
        .padding(.horizontal, TaptionScheduleWidgetMetrics(family: family).horizontalPadding)
        .padding(.vertical, TaptionScheduleWidgetMetrics(family: family).verticalPadding)
        .widgetURL(deepLinkURL(payload: freshestPayload, at: .now))
    }

    private var emptyWidgetState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
            Text("앱을 열어 오늘 기록을 동기화하세요")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)
                .multilineTextAlignment(.center)
            Text("일정 · 위치 · 이동 · 활동이 여기에 표시됩니다")
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
        walkPose: TaptionWidgetCatWalkPose
    ) -> some View {
        HStack(spacing: 0) {
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
                    style: payload.catStyle,
                    reducesMotion: payload.reducesMotion ?? false,
                    pose: walkPose
                )
                .frame(width: metrics.catWidth, height: metrics.catHeight)
            }
            .buttonStyle(.plain)
            .padding(.leading, 5)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                Image(systemName: weatherSymbol(payload: payload))
                    .font(.system(size: metrics.weatherIconSize, weight: .semibold))
                Text(weatherAndTimeLabel(at: date, payload: payload))
                    .font(.system(size: metrics.weatherFontSize, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(WidgetPalette.weather)
        }
        .frame(height: metrics.headerHeight)
        .padding(.bottom, metrics.headerBottomSpacing)
    }

    private var freshestPayload: TaptionWidgetPayload {
        let stored = TaptionWidgetSharedStore.readPayload()
        return TaptionWidgetPayloadSyncPolicy.freshest(
            groundTruth: entry.payload,
            cached: stored
        )
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

    private func preferredCatAction(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> TaptionWidgetCatAction? {
        guard let item = visibleItems(in: payload).first(where: {
            $0.resolvedLane == .action
                && !$0.isFixed
                && $0.startsAt <= date
                && date < $0.endsAt
        }) else {
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
            return "집중 중"
        }
        return currentItem(at: date, payload: payload) == nil
            ? "대기"
            : "기록 중"
    }

    private func weatherSymbol(payload: TaptionWidgetPayload) -> String {
        payload.weatherSymbolName ?? "clock"
    }

    private func weatherAndTimeLabel(
        at date: Date,
        payload: TaptionWidgetPayload
    ) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let temperature = payload.temperatureCelsius else {
            return time
        }
        return "\(temperature.rounded().formatted())° · \(time)"
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
        freshestPayload.reducesMotion == true
            ? 60
            : TaptionWidgetCatWalkEngine.defaultStepDuration
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
            let labelWidth: CGFloat = 62
            let axisHeight: CGFloat = 17
            let trackWidth = max(1, proxy.size.width - labelWidth)
            let viewportHeight = max(1, proxy.size.height - axisHeight)
            let visibleRowCount = max(
                1,
                min(
                    visibleRowLimit,
                    lanes.count
                )
            )
            let rowHeight = max(
                23,
                viewportHeight / CGFloat(visibleRowCount)
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
                                        2,
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
        Label(lane.title, systemImage: lane.systemImage)
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
        min(20, max(14, rowHeight - 7))
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
    let reducesMotion: Bool
    let pose: TaptionWidgetCatWalkPose

    var body: some View {
        GeometryReader { proxy in
            let catWidth = min(34, proxy.size.width)
            let visualInset = catWidth * 0.04
            let available = max(
                0,
                proxy.size.width - catWidth + (visualInset * 2)
            )
            let progress = reducesMotion ? 0.5 : pose.progress
            let isMoving = !reducesMotion
                && pose.action.movesAcrossTrack
                && !pose.isAtEndpoint

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

                WidgetCat(
                    style: style,
                    isRunning: isMoving,
                    reducesMotion: reducesMotion,
                    animationPhase: pose.legPhase,
                    action: reducesMotion ? .sitting : pose.action,
                    tailSwing: reducesMotion ? 0 : pose.tailSwing,
                    headTiltDegrees: reducesMotion
                        ? 0
                        : pose.headTiltDegrees
                )
                .frame(width: catWidth, height: 25)
                .scaleEffect(
                    x: pose.facesLeft && !reducesMotion ? -1 : 1,
                    y: 1
                )
                .offset(x: (available * progress) - visualInset)
            }
        }
        .accessibilityLabel(
            "\(CatPalette(style: style).name) 고양이가 \(actionLabel)"
        )
    }

    private var actionLabel: String {
        switch reducesMotion ? .sitting : pose.action {
        case .walking: "걷는 중"
        case .running: "달리는 중"
        case .sitting: "앉아 있는 중"
        case .sleeping: "자는 중"
        case .grooming: "그루밍하는 중"
        case .eating: "밥 먹는 중"
        case .startled: "놀란 상태"
        case .ballPlay: "공을 잡고 노는 중"
        case .fishingPlay: "낚싯대 장난감으로 노는 중"
        }
    }
}

private struct WidgetCat: View {
    let style: String
    var isRunning: Bool = true
    var reducesMotion: Bool = false
    var animationPhase: Int = 0
    var action: TaptionWidgetCatAction = .walking
    var tailSwing: Double = 0
    var headTiltDegrees: Double = 0

    var body: some View {
        Canvas { rawContext, size in
            let scaleX = size.width / 40
            let scaleY = size.height / 27
            var context = rawContext
            context.scaleBy(x: scaleX, y: scaleY)
            let effectivePhase = isRunning && !reducesMotion
                ? animationPhase
                : 0

            if action == .running && !reducesMotion {
                drawWalkingPuffs(in: &context, phase: effectivePhase)
            }
            drawShadow(in: &context)
            drawCat(in: &context, phase: effectivePhase)
        }
        .accessibilityLabel(accessibilityName)
    }

    private func drawWalkingPuffs(
        in context: inout GraphicsContext,
        phase: Int
    ) {
        let bounce = Double(phase % 2)
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 4 - bounce,
                    y: 18 + bounce,
                    width: 3,
                    height: 2
                )
            ),
            with: .color(Color.white.opacity(0.82))
        )
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 1 + bounce,
                    y: 20 - bounce,
                    width: 2,
                    height: 1.5
                )
            ),
            with: .color(Color.white.opacity(0.55))
        )
    }

    private func drawShadow(in context: inout GraphicsContext) {
        context.fill(
            Path(ellipseIn: CGRect(x: 7.5, y: 23.2, width: 30, height: 2.8)),
            with: .color(.black.opacity(0.15))
        )
    }

    private func drawCat(in context: inout GraphicsContext, phase: Int) {
        let palette = CatPalette(style: style)
        let outline = GraphicsContext.Shading.color(palette.outline)
        let faceLine = style == "black"
            ? Color.white.opacity(0.82)
            : palette.outline
        let pink = Color(red: 1, green: 0.61, blue: 0.67)
        let furHighlight = Color.white.opacity(
            style == "white" ? 0.64 : 0.34
        )
        let detailLine = style == "black"
            ? Color.white.opacity(0.64)
            : palette.outline.opacity(0.58)
        let stroke = StrokeStyle(
            lineWidth: 2.2,
            lineCap: .round,
            lineJoin: .round
        )
        let runningPhase = phase % 4
        let bodyLift: Double = switch action {
        case .running:
            runningPhase == 1 || runningPhase == 3 ? -1.2 : 0.55
        case .walking:
            runningPhase == 1 || runningPhase == 3 ? -0.65 : 0.3
        case .startled:
            -1.2
        default:
            0
        }
        let faceTiltSlope = max(
            -12,
            min(12, headTiltDegrees)
        ) / 52
        func faceY(_ x: Double, _ y: Double) -> Double {
            y + bodyLift + ((x - 32.3) * faceTiltSlope)
        }
        let tailTip: CGPoint = switch action {
        case .startled:
            CGPoint(x: 4.2, y: 0.9)
        case .sleeping:
            CGPoint(x: 3.8, y: 17.2 + tailSwing)
        case .sitting, .grooming, .eating, .ballPlay, .fishingPlay:
            CGPoint(x: 3.8, y: 9.0 + tailSwing * 2.4)
        default:
            CGPoint(x: 3.8, y: 6.4 + tailSwing * 2.5)
        }
        let tailControl1: CGPoint = switch action {
        case .startled:
            CGPoint(x: 6.5, y: 10.0)
        case .sleeping:
            CGPoint(x: 8.0, y: 18.8)
        default:
            CGPoint(x: 5.0, y: 12.6 + tailSwing)
        }
        let tailControl2: CGPoint = switch action {
        case .startled:
            CGPoint(x: 1.8, y: 6.5)
        case .sleeping:
            CGPoint(x: 2.2, y: 19.2)
        default:
            CGPoint(x: 1.8, y: 10.0 + tailSwing * 1.3)
        }

        var tail = Path()
        tail.move(to: CGPoint(x: 11, y: 12 + bodyLift))
        tail.addCurve(
            to: tailTip,
            control1: tailControl1,
            control2: tailControl2
        )
        context.stroke(
            tail,
            with: outline,
            style: StrokeStyle(
                lineWidth: action == .startled ? 7.4 : 4.1,
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.stroke(
            tail,
            with: .color(palette.base),
            style: StrokeStyle(
                lineWidth: action == .startled ? 5.7 : 2.75,
                lineCap: .round,
                lineJoin: .round
            )
        )

        if action == .startled {
            for y in [3.2, 6.0, 8.8] {
                var raccoonBand = Path()
                raccoonBand.move(to: CGPoint(x: 2.3, y: y))
                raccoonBand.addLine(to: CGPoint(x: 6.6, y: y + 0.7))
                context.stroke(
                    raccoonBand,
                    with: .color(palette.stripe.opacity(0.88)),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                )
            }
        } else if style == "mackerel" || style == "cheese" {
            for offset in [0.0, 2.2, 4.4] {
                var tailStripe = Path()
                tailStripe.move(
                    to: CGPoint(
                        x: 4.1 + offset * 0.72,
                        y: tailTip.y + 1.0 + offset * 0.72
                    )
                )
                tailStripe.addLine(
                    to: CGPoint(
                        x: 5.8 + offset * 0.72,
                        y: tailTip.y + 1.8 + offset * 0.72
                    )
                )
                context.stroke(
                    tailStripe,
                    with: .color(palette.stripe),
                    style: StrokeStyle(
                        lineWidth: 0.8,
                        lineCap: .round
                    )
                )
            }
        } else if style == "calico" || style == "cow" {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: tailTip.x - 1.45,
                        y: tailTip.y - 1.35,
                        width: 2.9,
                        height: 2.7
                    )
                ),
                with: .color(
                    style == "calico" ? palette.orange : palette.dark
                )
            )
        }

        let body = Path(
            ellipseIn: CGRect(x: 9.5, y: 6 + bodyLift, width: 21, height: 12)
        )
        context.fill(body, with: .color(palette.base))
        context.stroke(body, with: outline, style: StrokeStyle(lineWidth: 1))

        var backHighlight = Path()
        backHighlight.move(to: CGPoint(x: 12.2, y: 8.7 + bodyLift))
        backHighlight.addCurve(
            to: CGPoint(x: 23.7, y: 7.5 + bodyLift),
            control1: CGPoint(x: 15.2, y: 6.8 + bodyLift),
            control2: CGPoint(x: 20.6, y: 6.4 + bodyLift)
        )
        context.stroke(
            backHighlight,
            with: .color(furHighlight),
            style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
        )

        var bellyShade = Path()
        bellyShade.move(to: CGPoint(x: 14.4, y: 16.2 + bodyLift))
        bellyShade.addCurve(
            to: CGPoint(x: 24.8, y: 16.7 + bodyLift),
            control1: CGPoint(x: 17.8, y: 18.0 + bodyLift),
            control2: CGPoint(x: 22.0, y: 18.0 + bodyLift)
        )
        context.stroke(
            bellyShade,
            with: .color(detailLine.opacity(0.42)),
            style: StrokeStyle(lineWidth: 0.65, lineCap: .round)
        )

        if style == "calico" {
            var orangePatch = Path()
            orangePatch.move(to: CGPoint(x: 10.5, y: 10 + bodyLift))
            orangePatch.addCurve(
                to: CGPoint(x: 19, y: 6.6 + bodyLift),
                control1: CGPoint(x: 12.9, y: 6.6 + bodyLift),
                control2: CGPoint(x: 16.7, y: 5.3 + bodyLift)
            )
            orangePatch.addLine(to: CGPoint(x: 17.5, y: 17.5 + bodyLift))
            orangePatch.addCurve(
                to: CGPoint(x: 10.5, y: 14 + bodyLift),
                control1: CGPoint(x: 14.2, y: 17.3 + bodyLift),
                control2: CGPoint(x: 11.9, y: 16.1 + bodyLift)
            )
            orangePatch.closeSubpath()
            context.fill(orangePatch, with: .color(palette.orange))

            var darkPatch = Path()
            darkPatch.move(to: CGPoint(x: 21, y: 6.2 + bodyLift))
            darkPatch.addCurve(
                to: CGPoint(x: 29.5, y: 11.3 + bodyLift),
                control1: CGPoint(x: 24.8, y: 6.4 + bodyLift),
                control2: CGPoint(x: 28.1, y: 8.2 + bodyLift)
            )
            darkPatch.addLine(to: CGPoint(x: 25.7, y: 16.5 + bodyLift))
            darkPatch.addLine(to: CGPoint(x: 20.4, y: 17.2 + bodyLift))
            darkPatch.closeSubpath()
            context.fill(darkPatch, with: .color(palette.dark))
        } else if style == "cow" {
            context.fill(
                Path(ellipseIn: CGRect(x: 13, y: 7 + bodyLift, width: 7, height: 7)),
                with: .color(palette.dark)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: 22, y: 11 + bodyLift, width: 6, height: 5)),
                with: .color(palette.dark)
            )
        }

        if style == "mackerel" || style == "cheese" {
            for x in [15.0, 19.0, 23.5] {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: 7 + bodyLift))
                stripe.addLine(to: CGPoint(x: x - 0.5, y: 11 + bodyLift))
                context.stroke(
                    stripe,
                    with: .color(palette.stripe),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
            }
        }

        var ears = Path()
        ears.move(to: CGPoint(x: 25.4, y: 5.8 + bodyLift))
        ears.addLine(to: CGPoint(x: 26.1, y: 0.7 + bodyLift))
        ears.addLine(to: CGPoint(x: 30.6, y: 4.2 + bodyLift))
        ears.move(to: CGPoint(x: 32.1, y: 4.2 + bodyLift))
        ears.addLine(to: CGPoint(x: 36.7, y: 0.8 + bodyLift))
        ears.addLine(to: CGPoint(x: 37.2, y: 6.7 + bodyLift))
        context.fill(ears, with: .color(palette.base))
        context.stroke(
            ears,
            with: outline,
            style: StrokeStyle(
                lineWidth: 1.2,
                lineCap: .round,
                lineJoin: .round
            )
        )

        var innerEars = Path()
        innerEars.move(to: CGPoint(x: 26.6, y: 4.3 + bodyLift))
        innerEars.addLine(to: CGPoint(x: 26.8, y: 2.1 + bodyLift))
        innerEars.addLine(to: CGPoint(x: 28.9, y: 4.2 + bodyLift))
        innerEars.closeSubpath()
        innerEars.move(to: CGPoint(x: 34.0, y: 4.1 + bodyLift))
        innerEars.addLine(to: CGPoint(x: 36.1, y: 2.1 + bodyLift))
        innerEars.addLine(to: CGPoint(x: 36.2, y: 4.8 + bodyLift))
        innerEars.closeSubpath()
        context.fill(innerEars, with: .color(pink.opacity(0.76)))

        let head = Path(
            ellipseIn: CGRect(
                x: 24.1,
                y: 2.8 + bodyLift,
                width: 13.5,
                height: 13.4
            )
        )
        context.fill(head, with: .color(palette.base))
        context.stroke(head, with: outline, style: StrokeStyle(lineWidth: 1.1))

        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 26.1,
                    y: 4.5 + bodyLift,
                    width: 7.8,
                    height: 4.2
                )
            ),
            with: .color(furHighlight.opacity(0.54))
        )

        if style == "calico" {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: 24.8,
                        y: 3.6 + bodyLift,
                        width: 5.3,
                        height: 4.2
                    )
                ),
                with: .color(palette.orange)
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: 33.5,
                        y: 4.2 + bodyLift,
                        width: 3.4,
                        height: 3.8
                    )
                ),
                with: .color(palette.dark)
            )
        } else if style == "cow" {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: 24.6,
                        y: 3.5 + bodyLift,
                        width: 5.4,
                        height: 4.5
                    )
                ),
                with: .color(palette.dark)
            )
        } else if style == "mackerel" || style == "cheese" {
            for x in [28.5, 31.0, 33.5] {
                var foreheadStripe = Path()
                foreheadStripe.move(
                    to: CGPoint(x: x, y: 3.7 + bodyLift)
                )
                foreheadStripe.addLine(
                    to: CGPoint(x: x - 0.3, y: 5.5 + bodyLift)
                )
                context.stroke(
                    foreheadStripe,
                    with: .color(palette.stripe),
                    style: StrokeStyle(
                        lineWidth: 0.75,
                        lineCap: .round
                    )
                )
            }
        }

        var collar = Path()
        collar.move(to: CGPoint(x: 25.7, y: 14.0 + bodyLift))
        collar.addCurve(
            to: CGPoint(x: 31.1, y: 15.0 + bodyLift),
            control1: CGPoint(x: 27.2, y: 14.8 + bodyLift),
            control2: CGPoint(x: 29.6, y: 15.1 + bodyLift)
        )
        context.stroke(
            collar,
            with: .color(Color(red: 0.86, green: 0.28, blue: 0.26)),
            style: StrokeStyle(lineWidth: 0.85, lineCap: .round)
        )
        let bell = Path(
            ellipseIn: CGRect(
                x: 28.3,
                y: 14.4 + bodyLift,
                width: 1.65,
                height: 1.65
            )
        )
        context.fill(
            bell,
            with: .color(Color(red: 0.98, green: 0.73, blue: 0.19))
        )
        context.stroke(
            bell,
            with: .color(palette.outline.opacity(0.72)),
            style: StrokeStyle(lineWidth: 0.35)
        )

        let muzzle = Path(
            ellipseIn: CGRect(
                x: 29.4,
                y: 9.3 + bodyLift,
                width: 5.7,
                height: 4.5
            )
        )
        context.fill(muzzle, with: .color(Color.white.opacity(0.60)))

        let closesEyes = action == .sleeping
            || action == .eating
            || (action == .grooming && runningPhase.isMultiple(of: 2))
        for eyeX in [27.35, 33.15] {
            let eyeY = faceY(eyeX, 6.85)
            if closesEyes {
                var closedEye = Path()
                closedEye.move(to: CGPoint(x: eyeX, y: eyeY + 1.25))
                closedEye.addCurve(
                    to: CGPoint(x: eyeX + 2.15, y: eyeY + 1.25),
                    control1: CGPoint(x: eyeX + 0.55, y: eyeY + 2.0),
                    control2: CGPoint(x: eyeX + 1.55, y: eyeY + 2.0)
                )
                context.stroke(
                    closedEye,
                    with: .color(faceLine),
                    style: StrokeStyle(lineWidth: 0.72, lineCap: .round)
                )
            } else {
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: eyeX,
                            y: eyeY,
                            width: 2.15,
                            height: 2.45
                        )
                    ),
                    with: .color(palette.eye)
                )
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: eyeX + 0.86,
                            y: eyeY + 0.48,
                            width: 0.42,
                            height: 1.45
                        )
                    ),
                    with: .color(Color.black.opacity(0.90))
                )
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: eyeX + 0.48,
                            y: eyeY + 0.26,
                            width: 0.62,
                            height: 0.68
                        )
                    ),
                    with: .color(Color.white.opacity(0.96))
                )
            }
        }

        var eyebrows = Path()
        eyebrows.move(to: CGPoint(x: 27.4, y: faceY(27.4, 6.25)))
        eyebrows.addCurve(
            to: CGPoint(x: 29.4, y: faceY(29.4, 6.1)),
            control1: CGPoint(x: 28.0, y: faceY(28.0, 5.9)),
            control2: CGPoint(x: 28.8, y: faceY(28.8, 5.85))
        )
        eyebrows.move(to: CGPoint(x: 33.2, y: faceY(33.2, 6.1)))
        eyebrows.addCurve(
            to: CGPoint(x: 35.3, y: faceY(35.3, 6.3)),
            control1: CGPoint(x: 33.8, y: faceY(33.8, 5.85)),
            control2: CGPoint(x: 34.7, y: faceY(34.7, 5.95))
        )
        context.stroke(
            eyebrows,
            with: .color(detailLine.opacity(0.72)),
            style: StrokeStyle(lineWidth: 0.42, lineCap: .round)
        )

        let noseY = faceY(32.4, 10.15)
        var nose = Path()
        nose.move(to: CGPoint(x: 31.55, y: noseY + 0.18))
        nose.addCurve(
            to: CGPoint(x: 33.25, y: noseY + 0.18),
            control1: CGPoint(x: 31.85, y: noseY - 0.35),
            control2: CGPoint(x: 32.95, y: noseY - 0.35)
        )
        nose.addCurve(
            to: CGPoint(x: 32.4, y: noseY + 1.05),
            control1: CGPoint(x: 33.15, y: noseY + 0.65),
            control2: CGPoint(x: 32.7, y: noseY + 0.95)
        )
        nose.addCurve(
            to: CGPoint(x: 31.55, y: noseY + 0.18),
            control1: CGPoint(x: 32.1, y: noseY + 0.95),
            control2: CGPoint(x: 31.65, y: noseY + 0.65)
        )
        context.fill(nose, with: .color(pink))

        var smile = Path()
        smile.move(to: CGPoint(x: 32.4, y: noseY + 0.95))
        smile.addCurve(
            to: CGPoint(x: 31.35, y: noseY + 1.78),
            control1: CGPoint(x: 32.15, y: noseY + 1.55),
            control2: CGPoint(x: 31.7, y: noseY + 1.78)
        )
        smile.move(to: CGPoint(x: 32.4, y: noseY + 0.95))
        smile.addCurve(
            to: CGPoint(x: 33.45, y: noseY + 1.78),
            control1: CGPoint(x: 32.65, y: noseY + 1.55),
            control2: CGPoint(x: 33.1, y: noseY + 1.78)
        )
        context.stroke(
            smile,
            with: .color(faceLine),
            style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
        )

        if action == .grooming && runningPhase == 1 {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: 31.75,
                        y: noseY + 1.45,
                        width: 1.3,
                        height: 1.5
                    )
                ),
                with: .color(pink.opacity(0.90))
            )
        }

        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 26.2,
                    y: faceY(27.2, 10.65),
                    width: 2.1,
                    height: 1.2
                )
            ),
            with: .color(pink.opacity(0.48))
        )
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 35.2,
                    y: faceY(36.0, 10.65),
                    width: 1.8,
                    height: 1.2
                )
            ),
            with: .color(pink.opacity(0.48))
        )

        for point in [
            CGPoint(x: 29.7, y: faceY(29.7, 11.3)),
            CGPoint(x: 29.9, y: faceY(29.9, 12.0)),
            CGPoint(x: 34.8, y: faceY(34.8, 11.3)),
            CGPoint(x: 34.6, y: faceY(34.6, 12.0)),
        ] {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - 0.18,
                        y: point.y - 0.18,
                        width: 0.36,
                        height: 0.36
                    )
                ),
                with: .color(detailLine.opacity(0.78))
            )
        }

        var whiskers = Path()
        whiskers.move(to: CGPoint(x: 29.5, y: faceY(29.5, 10.95)))
        whiskers.addLine(to: CGPoint(x: 25.8, y: faceY(25.8, 9.9)))
        whiskers.move(to: CGPoint(x: 29.5, y: faceY(29.5, 11.7)))
        whiskers.addLine(to: CGPoint(x: 25.5, y: faceY(25.5, 11.7)))
        whiskers.move(to: CGPoint(x: 29.6, y: faceY(29.6, 12.35)))
        whiskers.addLine(to: CGPoint(x: 26.0, y: faceY(26.0, 13.2)))
        whiskers.move(to: CGPoint(x: 35.0, y: faceY(35.0, 10.95)))
        whiskers.addLine(to: CGPoint(x: 38.8, y: faceY(38.8, 9.9)))
        whiskers.move(to: CGPoint(x: 35.0, y: faceY(35.0, 11.7)))
        whiskers.addLine(to: CGPoint(x: 39.0, y: faceY(39.0, 11.8)))
        whiskers.move(to: CGPoint(x: 34.9, y: faceY(34.9, 12.35)))
        whiskers.addLine(to: CGPoint(x: 38.6, y: faceY(38.6, 13.25)))
        context.stroke(
            whiskers,
            with: .color(faceLine.opacity(0.72)),
            style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
        )

        let legPairs: [(CGPoint, CGPoint)] = switch action {
        case .walking:
            runningLegPairs(phase: runningPhase, lift: bodyLift)
        case .running:
            sprintingLegPairs(phase: runningPhase, lift: bodyLift)
        case .sleeping:
            []
        case .sitting, .grooming, .eating, .ballPlay, .fishingPlay:
            [
                (CGPoint(x: 18, y: 16), CGPoint(x: 18, y: 20.5)),
                (CGPoint(x: 23, y: 16.5), CGPoint(x: 23, y: 20.5)),
                (CGPoint(x: 27, y: 16.5), CGPoint(x: 27, y: 20.5)),
                (CGPoint(x: 30, y: 15.5), CGPoint(x: 30, y: 20.0)),
            ]
        case .startled:
            [
                (CGPoint(x: 15, y: 16), CGPoint(x: 14, y: 20)),
                (CGPoint(x: 20, y: 17), CGPoint(x: 20, y: 20)),
                (CGPoint(x: 25, y: 17), CGPoint(x: 25, y: 20)),
                (CGPoint(x: 30, y: 15.5), CGPoint(x: 30, y: 19.5)),
            ]
        }
        for (start, end) in legPairs {
            var leg = Path()
            leg.move(to: start)
            leg.addLine(to: end)
            context.stroke(leg, with: outline, style: stroke)
            let paw = Path(
                ellipseIn: CGRect(
                    x: end.x - 1.45,
                    y: end.y - 0.7,
                    width: 3.1,
                    height: 1.55
                )
            )
            context.fill(paw, with: .color(palette.base))
            context.stroke(
                paw,
                with: outline,
                style: StrokeStyle(lineWidth: 0.65)
            )
            for toeOffset in [-0.42, 0.42] {
                var toe = Path()
                toe.move(
                    to: CGPoint(
                        x: end.x + toeOffset,
                        y: end.y - 0.2
                    )
                )
                toe.addLine(
                    to: CGPoint(
                        x: end.x + toeOffset,
                        y: end.y + 0.38
                    )
                )
                context.stroke(
                    toe,
                    with: .color(detailLine.opacity(0.72)),
                    style: StrokeStyle(
                        lineWidth: 0.28,
                        lineCap: .round
                    )
                )
            }
        }

        drawActionDetails(
            in: &context,
            palette: palette,
            outline: outline,
            faceLine: faceLine,
            pink: pink,
            phase: runningPhase,
            bodyLift: bodyLift
        )
    }

    private func drawActionDetails(
        in context: inout GraphicsContext,
        palette: CatPalette,
        outline: GraphicsContext.Shading,
        faceLine: Color,
        pink: Color,
        phase: Int,
        bodyLift: Double
    ) {
        if action == .sitting
            || action == .grooming
            || action == .eating
            || action == .ballPlay
            || action == .fishingPlay
        {
            var chestTuft = Path()
            chestTuft.move(to: CGPoint(x: 26.0, y: 13.7 + bodyLift))
            chestTuft.addLine(to: CGPoint(x: 27.2, y: 16.9 + bodyLift))
            chestTuft.addLine(to: CGPoint(x: 28.3, y: 15.8 + bodyLift))
            chestTuft.addLine(to: CGPoint(x: 29.2, y: 17.2 + bodyLift))
            chestTuft.addLine(to: CGPoint(x: 30.4, y: 14.1 + bodyLift))
            chestTuft.closeSubpath()
            context.fill(
                chestTuft,
                with: .color(Color.white.opacity(0.66))
            )
        }

        switch action {
        case .grooming:
            let pawY = phase.isMultiple(of: 2) ? 9.2 : 10.4
            var raisedArm = Path()
            raisedArm.move(to: CGPoint(x: 27.8, y: 15.8 + bodyLift))
            raisedArm.addCurve(
                to: CGPoint(x: 34.6, y: pawY + bodyLift),
                control1: CGPoint(x: 29.8, y: 13.2 + bodyLift),
                control2: CGPoint(x: 32.2, y: 10.2 + bodyLift)
            )
            context.stroke(
                raisedArm,
                with: outline,
                style: StrokeStyle(lineWidth: 3.0, lineCap: .round)
            )
            context.stroke(
                raisedArm,
                with: .color(palette.base),
                style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
            )
            let groomingPaw = Path(
                ellipseIn: CGRect(
                    x: 33.3,
                    y: pawY - 1.1 + bodyLift,
                    width: 3.0,
                    height: 2.5
                )
            )
            context.fill(groomingPaw, with: .color(palette.base))
            context.stroke(
                groomingPaw,
                with: outline,
                style: StrokeStyle(lineWidth: 0.6)
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: 34.25,
                        y: pawY - 0.25 + bodyLift,
                        width: 0.9,
                        height: 0.65
                    )
                ),
                with: .color(pink.opacity(0.62))
            )

        case .eating:
            let bowl = Path(
                roundedRect: CGRect(x: 28.2, y: 19.3, width: 10.5, height: 4.1),
                cornerRadius: 1.5
            )
            context.fill(
                bowl,
                with: .color(Color(red: 0.45, green: 0.68, blue: 0.86))
            )
            context.stroke(
                bowl,
                with: outline,
                style: StrokeStyle(lineWidth: 0.7)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: 28.5, y: 18.7, width: 9.9, height: 2.2)),
                with: .color(Color(red: 0.61, green: 0.39, blue: 0.23))
            )
            for x in [31.0, 33.4, 35.8] {
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: 18.55, width: 1.3, height: 1.0)),
                    with: .color(Color(red: 0.82, green: 0.58, blue: 0.31))
                )
            }

        case .sleeping:
            context.fill(
                Path(ellipseIn: CGRect(x: 20.0, y: 16.1, width: 8.5, height: 4.2)),
                with: .color(palette.base)
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: 20.0, y: 16.1, width: 8.5, height: 4.2)),
                with: outline,
                style: StrokeStyle(lineWidth: 0.65)
            )
            for origin in [CGPoint(x: 34.8, y: 3.1), CGPoint(x: 37.0, y: 0.8)] {
                var sleepMark = Path()
                sleepMark.move(to: origin)
                sleepMark.addLine(to: CGPoint(x: origin.x + 2.0, y: origin.y))
                sleepMark.addLine(
                    to: CGPoint(x: origin.x, y: origin.y + 2.0)
                )
                sleepMark.addLine(
                    to: CGPoint(x: origin.x + 2.0, y: origin.y + 2.0)
                )
                context.stroke(
                    sleepMark,
                    with: .color(faceLine.opacity(0.72)),
                    style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
                )
            }

        case .startled:
            for ray in [
                (CGPoint(x: 37.2, y: 2.6), CGPoint(x: 39.0, y: 1.5)),
                (CGPoint(x: 38.0, y: 4.2), CGPoint(x: 39.7, y: 4.0)),
                (CGPoint(x: 35.6, y: 1.2), CGPoint(x: 36.0, y: 0.0)),
            ] {
                var surpriseRay = Path()
                surpriseRay.move(to: ray.0)
                surpriseRay.addLine(to: ray.1)
                context.stroke(
                    surpriseRay,
                    with: .color(Color(red: 0.96, green: 0.61, blue: 0.12)),
                    style: StrokeStyle(lineWidth: 0.9, lineCap: .round)
                )
            }

        case .ballPlay:
            var reachingPaw = Path()
            reachingPaw.move(to: CGPoint(x: 29.0, y: 15.8 + bodyLift))
            reachingPaw.addCurve(
                to: CGPoint(x: 35.1, y: 18.2),
                control1: CGPoint(x: 31.1, y: 15.5 + bodyLift),
                control2: CGPoint(x: 33.1, y: 16.7)
            )
            context.stroke(
                reachingPaw,
                with: outline,
                style: StrokeStyle(lineWidth: 2.7, lineCap: .round)
            )
            context.stroke(
                reachingPaw,
                with: .color(palette.base),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )

            let ballOffset = phase.isMultiple(of: 2) ? -0.8 : 0.5
            let ballRect = CGRect(
                x: 34.0,
                y: 18.1 + ballOffset,
                width: 5.2,
                height: 5.2
            )
            context.fill(
                Path(ellipseIn: ballRect),
                with: .color(Color(red: 0.97, green: 0.55, blue: 0.16))
            )
            context.stroke(
                Path(ellipseIn: ballRect),
                with: .color(Color(red: 0.62, green: 0.28, blue: 0.11)),
                style: StrokeStyle(lineWidth: 0.65)
            )
            var ballSeam = Path()
            ballSeam.move(
                to: CGPoint(x: ballRect.minX + 1.0, y: ballRect.midY)
            )
            ballSeam.addCurve(
                to: CGPoint(x: ballRect.maxX - 0.9, y: ballRect.midY),
                control1: CGPoint(
                    x: ballRect.midX - 0.8,
                    y: ballRect.minY + 0.6
                ),
                control2: CGPoint(
                    x: ballRect.midX + 0.8,
                    y: ballRect.maxY - 0.6
                )
            )
            context.stroke(
                ballSeam,
                with: .color(Color.white.opacity(0.76)),
                style: StrokeStyle(lineWidth: 0.5, lineCap: .round)
            )

            for offset in [0.0, 1.8] {
                var motionLine = Path()
                motionLine.move(
                    to: CGPoint(x: 37.0 + offset, y: 16.5 - offset * 0.25)
                )
                motionLine.addLine(
                    to: CGPoint(x: 38.6 + offset, y: 15.5 - offset * 0.25)
                )
                context.stroke(
                    motionLine,
                    with: .color(Color(red: 0.96, green: 0.61, blue: 0.12)),
                    style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
                )
            }

        case .fishingPlay:
            var reachingPaw = Path()
            reachingPaw.move(to: CGPoint(x: 28.8, y: 15.8 + bodyLift))
            reachingPaw.addCurve(
                to: CGPoint(x: 34.0, y: 13.0),
                control1: CGPoint(x: 30.6, y: 15.0 + bodyLift),
                control2: CGPoint(x: 32.2, y: 13.6)
            )
            context.stroke(
                reachingPaw,
                with: outline,
                style: StrokeStyle(lineWidth: 2.7, lineCap: .round)
            )
            context.stroke(
                reachingPaw,
                with: .color(palette.base),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )

            let rodTipY = phase.isMultiple(of: 2) ? 1.2 : 2.5
            var rod = Path()
            rod.move(to: CGPoint(x: 33.6, y: 13.1))
            rod.addLine(to: CGPoint(x: 38.4, y: rodTipY))
            context.stroke(
                rod,
                with: .color(Color(red: 0.51, green: 0.31, blue: 0.14)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
            )

            let toyX = phase.isMultiple(of: 2) ? 37.0 : 35.6
            var string = Path()
            string.move(to: CGPoint(x: 38.4, y: rodTipY))
            string.addCurve(
                to: CGPoint(x: toyX, y: 17.6),
                control1: CGPoint(x: 40.0, y: 7.0),
                control2: CGPoint(x: toyX + 1.5, y: 12.2)
            )
            context.stroke(
                string,
                with: .color(faceLine.opacity(0.72)),
                style: StrokeStyle(lineWidth: 0.35, lineCap: .round)
            )

            var feather = Path()
            feather.move(to: CGPoint(x: toyX, y: 17.2))
            feather.addCurve(
                to: CGPoint(x: toyX - 1.8, y: 21.8),
                control1: CGPoint(x: toyX - 2.4, y: 18.1),
                control2: CGPoint(x: toyX - 2.8, y: 20.7)
            )
            feather.addCurve(
                to: CGPoint(x: toyX, y: 17.2),
                control1: CGPoint(x: toyX + 0.2, y: 20.7),
                control2: CGPoint(x: toyX + 0.6, y: 18.4)
            )
            context.fill(
                feather,
                with: .color(Color(red: 0.95, green: 0.32, blue: 0.46))
            )
            var secondFeather = Path()
            secondFeather.move(to: CGPoint(x: toyX, y: 17.6))
            secondFeather.addCurve(
                to: CGPoint(x: toyX + 2.0, y: 21.1),
                control1: CGPoint(x: toyX + 2.3, y: 18.2),
                control2: CGPoint(x: toyX + 2.6, y: 20.1)
            )
            secondFeather.addCurve(
                to: CGPoint(x: toyX, y: 17.6),
                control1: CGPoint(x: toyX + 0.7, y: 20.8),
                control2: CGPoint(x: toyX + 0.4, y: 18.6)
            )
            context.fill(
                secondFeather,
                with: .color(Color(red: 0.98, green: 0.74, blue: 0.17))
            )

        case .walking, .running, .sitting:
            break
        }
    }

    private func sprintingLegPairs(
        phase: Int,
        lift: Double
    ) -> [(CGPoint, CGPoint)] {
        switch phase {
        case 0, 2:
            [
                (CGPoint(x: 14, y: 16 + lift), CGPoint(x: 8.5, y: 21.5)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 25, y: 21.5)),
                (CGPoint(x: 25, y: 16 + lift), CGPoint(x: 19, y: 21.2)),
                (CGPoint(x: 30, y: 15 + lift), CGPoint(x: 36, y: 19.5)),
            ]
        default:
            [
                (CGPoint(x: 14, y: 16 + lift), CGPoint(x: 20, y: 21.2)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 12.5, y: 21.6)),
                (CGPoint(x: 25, y: 16 + lift), CGPoint(x: 32, y: 20.7)),
                (CGPoint(x: 30, y: 15 + lift), CGPoint(x: 23, y: 20.5)),
            ]
        }
    }

    private func runningLegPairs(
        phase: Int,
        lift: Double
    ) -> [(CGPoint, CGPoint)] {
        switch phase {
        case 0:
            [
                (CGPoint(x: 14, y: 16.5 + lift), CGPoint(x: 11, y: 22)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 22, y: 22)),
                (CGPoint(x: 25, y: 16.5 + lift), CGPoint(x: 23, y: 22)),
                (CGPoint(x: 29, y: 15.5 + lift), CGPoint(x: 33, y: 20)),
            ]
        case 1:
            [
                (CGPoint(x: 14, y: 16 + lift), CGPoint(x: 17, y: 21)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 16, y: 22)),
                (CGPoint(x: 25, y: 16.4 + lift), CGPoint(x: 29, y: 21)),
                (CGPoint(x: 29, y: 15.6 + lift), CGPoint(x: 27, y: 20.5)),
            ]
        case 2:
            [
                (CGPoint(x: 14, y: 16.5 + lift), CGPoint(x: 20, y: 20.8)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 13, y: 21.8)),
                (CGPoint(x: 25, y: 16.5 + lift), CGPoint(x: 31, y: 21.3)),
                (CGPoint(x: 29, y: 15.5 + lift), CGPoint(x: 24, y: 21)),
            ]
        default:
            [
                (CGPoint(x: 14, y: 16 + lift), CGPoint(x: 10.5, y: 21.4)),
                (CGPoint(x: 19, y: 17 + lift), CGPoint(x: 22.5, y: 21.7)),
                (CGPoint(x: 25, y: 16.4 + lift), CGPoint(x: 22.5, y: 21)),
                (CGPoint(x: 29, y: 15.6 + lift), CGPoint(x: 33.5, y: 20.2)),
            ]
        }
    }

    private var accessibilityName: String {
        "\(CatPalette(style: style).name) 고양이"
    }
}

private struct CatPalette {
    let base: Color
    let outline: Color
    let eye: Color
    let orange: Color
    let dark: Color
    let stripe: Color
    let name: String

    init(style: String) {
        orange = Color(red: 0.86, green: 0.53, blue: 0.23)
        dark = Color(red: 0.22, green: 0.21, blue: 0.23)
        switch style {
        case "white":
            base = Color(red: 1, green: 0.996, blue: 0.98)
            outline = Color(red: 0.39, green: 0.39, blue: 0.41)
            eye = Color(red: 0.13, green: 0.13, blue: 0.14)
            stripe = outline
            name = "흰색"
        case "mackerel":
            base = Color(red: 0.55, green: 0.57, blue: 0.58)
            outline = Color(red: 0.27, green: 0.28, blue: 0.29)
            eye = Color(red: 1, green: 0.96, blue: 0.72)
            stripe = Color(red: 0.29, green: 0.31, blue: 0.32)
            name = "고등어"
        case "black":
            base = Color(red: 0.13, green: 0.13, blue: 0.14)
            outline = Color(red: 0.04, green: 0.04, blue: 0.04)
            eye = Color(red: 0.96, green: 0.83, blue: 0.37)
            stripe = outline
            name = "검정"
        case "gray":
            base = Color(red: 0.64, green: 0.65, blue: 0.67)
            outline = Color(red: 0.35, green: 0.37, blue: 0.39)
            eye = .white
            stripe = outline
            name = "회색"
        case "cheese":
            base = Color(red: 0.90, green: 0.63, blue: 0.30)
            outline = Color(red: 0.60, green: 0.39, blue: 0.17)
            eye = Color(red: 0.26, green: 0.19, blue: 0.12)
            stripe = Color(red: 0.66, green: 0.42, blue: 0.16)
            name = "치즈"
        case "cow":
            base = Color(red: 1, green: 0.996, blue: 0.98)
            outline = Color(red: 0.33, green: 0.34, blue: 0.35)
            eye = Color(red: 0.13, green: 0.13, blue: 0.14)
            stripe = outline
            name = "젖소무늬"
        default:
            base = Color(red: 0.97, green: 0.95, blue: 0.91)
            outline = Color(red: 0.31, green: 0.29, blue: 0.29)
            eye = Color(red: 0.13, green: 0.13, blue: 0.14)
            stripe = outline
            name = "삼색"
        }
    }
}

private enum WidgetPalette {
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
            let repository = try FilePlanRepository.appGroup()
            let source = try await repository.load()
            let updated = try TaptionWidgetCommandEngine.apply(
                command,
                to: source
            )
            try await repository.save(updated)
            refreshedPayload = TaptionWidgetPayloadFactory.make(
                from: updated
            )
            command.appliedToSharedRepository = true
        } catch {
            command.appliedToSharedRepository = false
        }

        if let refreshedPayload {
            try TaptionWidgetSharedStore.writePayload(refreshedPayload)
        }
        try TaptionWidgetSharedStore.appendCommand(command)
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

}

private extension Color {
    init(widgetHex value: String) {
        let normalized = value
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: normalized).scanHexInt64(&number)
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        switch normalized.count {
        case 3:
            red = ((number >> 8) & 0xF) * 17
            green = ((number >> 4) & 0xF) * 17
            blue = (number & 0xF) * 17
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

struct TaptionPlanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaptionActivityAttributes.self) { context in
            TaptionLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(
                    Color(red: 0.08, green: 0.08, blue: 0.09)
                )
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetCat(style: context.state.catStyle)
                        .frame(width: 30, height: 21)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        ProgressView(
                            timerInterval: context.state.startedAt...context.state.endsAt,
                            countsDown: false
                        )
                        .tint(Color(red: 0.48, green: 0.37, blue: 0.65))
                        Button(
                            intent: TaptionWidgetActionIntent(
                                planID: context.attributes.planID.uuidString,
                                action: .stopCurrentActivity
                            )
                        ) {
                            Text("종료")
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } compactLeading: {
                WidgetCat(style: context.state.catStyle)
                    .frame(width: 18, height: 14)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...context.state.endsAt)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                WidgetCat(style: context.state.catStyle)
                    .frame(width: 18, height: 13)
            }
            .keylineTint(Color(red: 0.48, green: 0.37, blue: 0.65))
        }
    }
}

private struct TaptionLiveActivityLockScreenView: View {
    let context: ActivityViewContext<TaptionActivityAttributes>

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(context.state.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text(remainingLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        Color(red: 0.78, green: 0.78, blue: 0.80)
                    )
            }

            ProgressView(
                timerInterval:
                    context.state.startedAt...context.state.endsAt,
                countsDown: false
            )
            .progressViewStyle(.linear)
            .tint(Color(red: 0.48, green: 0.37, blue: 0.65))
            .padding(.vertical, 13)

            HStack {
                Text(timeLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                Spacer()
                Button(
                    intent: TaptionWidgetActionIntent(
                        planID: context.attributes.planID.uuidString,
                        action: .stopCurrentActivity
                    )
                ) {
                    Text("종료")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WidgetPalette.ink)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            .white,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .widgetURL(
            URL(
                string:
                    "taptionplan://plan/\(context.attributes.planID.uuidString)"
            )
        )
    }

    private var remainingLabel: String {
        let minutes = max(
            0,
            Int(
                ceil(
                    context.state.endsAt.timeIntervalSinceNow / 60
                )
            )
        )
        return "\(minutes)분 남음"
    }

    private var timeLabel: String {
        let start = context.state.startedAt.formatted(
            date: .omitted,
            time: .shortened
        )
        let end = context.state.endsAt.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(start) → \(end)"
    }
}

#if DEBUG
#Preview(as: .systemMedium) {
    TaptionScheduleWidget()
} timeline: {
    TaptionScheduleEntry(date: .now, payload: .placeholder)
}

#Preview(as: .systemLarge) {
    TaptionScheduleWidget()
} timeline: {
    TaptionScheduleEntry(date: .now, payload: .placeholder)
}

#Preview(as: .systemExtraLarge) {
    TaptionScheduleWidget()
} timeline: {
    TaptionScheduleEntry(date: .now, payload: .placeholder)
}
#endif
