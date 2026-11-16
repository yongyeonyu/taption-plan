import ActivityKit
import AppIntents
import OSLog
import SwiftUI
import TaptionPlanCore
import WidgetKit

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

struct TaptionScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family

    // 공급자가 읽은 payload를 그대로 쓴다. 항목마다 공유 파일을 다시 읽지 않는다(REV1110A04).
    let entry: TaptionScheduleEntry

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
            let payload = entry.payload
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
        .widgetURL(deepLinkURL(payload: entry.payload, at: .now))
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
