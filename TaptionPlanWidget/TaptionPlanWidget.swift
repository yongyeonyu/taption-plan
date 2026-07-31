import ActivityKit
import AppIntents
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
                    : TaptionWidgetSharedStore.readPayload()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TaptionScheduleEntry>) -> Void
    ) {
        let now = Date.now
        let payload = TaptionWidgetSharedStore.readPayload()
        let horizon = now.addingTimeInterval(2 * 3_600)
        var refreshDates = TaptionWidgetPlaybackEngine.timelineDates(
            for: payload.items,
            from: now,
            horizon: horizon
        )
        if payload.reducesMotion != true {
            refreshDates.append(
                contentsOf: (1...60).map {
                    now.addingTimeInterval(Double($0) * 2)
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
}

struct TaptionScheduleWidget: Widget {
    let kind = TaptionWidgetKind.schedule

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TaptionScheduleProvider()
        ) { entry in
            TaptionScheduleWidgetView(entry: entry)
                .containerBackground(.white, for: .widget)
        }
        .configurationDisplayName("Taption 시간표")
        .description("현재선 중심의 시간표에서 계획을 바로 처리합니다.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

private struct TaptionScheduleWidgetView: View {
    let entry: TaptionScheduleEntry

    var body: some View {
        TimelineView(
            .periodic(
                from: entry.date,
                by: playbackInterval
            )
        ) { context in
            let playbackDate = max(entry.date, context.date)
            VStack(spacing: 0) {
                header(
                    at: playbackDate,
                    walkPose: TaptionWidgetCatWalkEngine.pose(
                        at: playbackDate
                    )
                )

                PrototypeWidgetTrack(
                    payload: entry.payload,
                    date: playbackDate
                )
                .frame(height: 112)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .widgetURL(deepLinkURL)
    }

    private func header(
        at date: Date,
        walkPose: TaptionWidgetCatWalkPose
    ) -> some View {
        HStack(spacing: 0) {
            Text("지금의 시간표")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)

            Text(statusLabel(at: date))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(WidgetPalette.focusInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(WidgetPalette.focusFill, in: Capsule())
                .padding(.leading, 5)

            Link(destination: URL(string: "taptionplan://cats")!) {
                WidgetWalkingCat(
                    style: entry.payload.catStyle,
                    reducesMotion: entry.payload.reducesMotion ?? false,
                    pose: walkPose
                )
                .frame(width: 48, height: 22)
            }
            .buttonStyle(.plain)
            .padding(.leading, 5)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                Image(systemName: weatherSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(weatherAndTimeLabel(at: date))
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(WidgetPalette.weather)
        }
        .frame(height: 20)
        .padding(.bottom, 10)
    }

    private var visibleItems: [TaptionWidgetItem] {
        entry.payload.items
            .filter { !$0.isCompleted }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func currentItem(at date: Date) -> TaptionWidgetItem? {
        visibleItems.first {
            $0.startsAt <= date && date < $0.endsAt
        }
    }

    private func actionItem(at date: Date) -> TaptionWidgetItem? {
        let actionableItems = visibleItems.filter {
            $0.resolvedLane == .action && !$0.isFixed
        }
        return actionableItems.first {
            $0.startsAt <= date && date < $0.endsAt
        }
            ?? actionableItems.first(where: { date < $0.startsAt })
            ?? actionableItems.last
    }

    private func statusLabel(at date: Date) -> String {
        if TaptionWidgetPlaybackEngine.activeItems(
            in: .action,
            from: entry.payload.items,
            at: date
        ).isEmpty == false {
            return "집중 중"
        }
        return currentItem(at: date) == nil ? "대기" : "기록 중"
    }

    private var weatherSymbol: String {
        entry.payload.weatherSymbolName ?? "clock"
    }

    private func weatherAndTimeLabel(at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let temperature = entry.payload.temperatureCelsius else {
            return time
        }
        return "\(temperature.rounded().formatted())° · \(time)"
    }

    private var deepLinkURL: URL? {
        guard let item = actionItem(at: entry.date) else {
            return URL(string: "taptionplan://today")
        }
        return URL(string: "taptionplan://plan/\(item.id.uuidString)")
    }

    private var playbackInterval: TimeInterval {
        entry.payload.reducesMotion == true ? 60 : 2
    }
}

private struct PrototypeWidgetTrack: View {
    let payload: TaptionWidgetPayload
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            let lanes = TaptionWidgetPlaybackEngine.lanes(
                for: payload.items,
                at: date
            )
            let labelWidth: CGFloat = 48
            let axisHeight: CGFloat = 14
            let trackWidth = max(1, proxy.size.width - labelWidth)
            let rowHeight = max(
                17,
                (proxy.size.height - axisHeight) / CGFloat(lanes.count)
            )
            let nowX = labelWidth + trackWidth / 2

            ZStack(alignment: .topLeading) {
                axisLabels(
                    labelWidth: labelWidth,
                    trackWidth: trackWidth
                )

                ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                    let y = axisHeight + CGFloat(index) * rowHeight
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

                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    Rectangle()
                        .fill(WidgetPalette.line.opacity(fraction == 0.5 ? 0.9 : 0.55))
                        .frame(width: 0.5, height: rowHeight * CGFloat(lanes.count))
                        .offset(
                            x: labelWidth + trackWidth * fraction,
                            y: axisHeight
                        )
                }

                ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                    let y = axisHeight + CGFloat(index) * rowHeight
                    ForEach(trackItems(in: lane).prefix(6)) { item in
                        itemBar(
                            item,
                            lane: lane,
                            trackWidth: trackWidth,
                            rowHeight: rowHeight
                        )
                        .offset(
                            x: labelWidth + trackWidth * fraction(item.startsAt),
                            y: y
                                + max(2, (rowHeight - barHeight(rowHeight)) / 2)
                        )
                    }
                }

                Rectangle()
                    .fill(WidgetPalette.now)
                    .frame(
                        width: 1.5,
                        height: rowHeight * CGFloat(lanes.count)
                    )
                    .offset(x: nowX - 0.75, y: axisHeight)

                Circle()
                    .fill(WidgetPalette.now)
                    .frame(width: 6, height: 6)
                    .offset(x: nowX - 3, y: axisHeight - 3)
            }
            .clipped()
        }
    }

    private var windowStart: Date {
        date.addingTimeInterval(-3 * 3_600)
    }

    private var windowEnd: Date {
        date.addingTimeInterval(3 * 3_600)
    }

    private func trackItems(
        in lane: TaptionWidgetLane
    ) -> [TaptionWidgetItem] {
        TaptionWidgetPlaybackEngine.visibleItems(
            in: lane,
            from: payload.items,
            at: date
        )
    }

    private func axisLabels(
        labelWidth: CGFloat,
        trackWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text("6시간")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: labelWidth - 4, alignment: .leading)
                .offset(x: 2)
            Text(windowStart.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .offset(x: labelWidth)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(WidgetPalette.now)
                .frame(width: 54)
                .offset(x: labelWidth + trackWidth / 2 - 27)
            Text(windowEnd.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: 45, alignment: .trailing)
                .offset(x: labelWidth + trackWidth - 45)
        }
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
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(WidgetPalette.ink.opacity(0.72))
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
            .fill(categoryColor(item, lane: lane).opacity(active ? 1 : 0.72))
            .frame(width: width, height: barHeight(rowHeight))
            .overlay(alignment: .leading) {
                if width >= 27 {
                    Text(item.title)
                        .font(.system(size: 7.5, weight: active ? .bold : .semibold))
                        .foregroundStyle(WidgetPalette.ink.opacity(0.72))
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
        min(14, max(10, rowHeight - 5))
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
        case .activity:
            return Color(red: 0.49, green: 0.68, blue: 0.51)
        case .action:
            break
        }
        return switch item.categoryID {
        case "exercise": Color(red: 0.996, green: 0.835, blue: 0.812)
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
            let catWidth = min(31, proxy.size.width)
            let available = max(0, proxy.size.width - catWidth)
            let progress = reducesMotion ? 0.5 : pose.progress

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

                WidgetCat(
                    style: style,
                    isRunning: !reducesMotion,
                    reducesMotion: reducesMotion,
                    animationPhase: pose.legPhase
                )
                .frame(width: catWidth, height: 22)
                .scaleEffect(
                    x: pose.facesLeft && !reducesMotion ? -1 : 1,
                    y: 1
                )
                .offset(x: available * progress)
            }
        }
        .accessibilityLabel(
            "\(CatPalette(style: style).name) 고양이가 걷는 중"
        )
    }
}

private struct WidgetCat: View {
    let style: String
    var isRunning: Bool = true
    var reducesMotion: Bool = false
    var animationPhase: Int = 0

    var body: some View {
        Canvas { rawContext, size in
            let scaleX = size.width / 40
            let scaleY = size.height / 27
            var context = rawContext
            context.scaleBy(x: scaleX, y: scaleY)
            let effectivePhase = isRunning && !reducesMotion
                ? animationPhase
                : 0

            if isRunning && !reducesMotion {
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
        let stroke = StrokeStyle(
            lineWidth: 2.2,
            lineCap: .round,
            lineJoin: .round
        )
        let runningPhase = phase % 4
        let bodyLift = isRunning
            ? (runningPhase == 1 || runningPhase == 3 ? -0.8 : 0.4)
            : 0
        let tailTip = runningPhase == 0 || runningPhase == 3
            ? CGPoint(x: 4, y: 5)
            : CGPoint(x: 3.5, y: 8.2)
        let tailControl1 = runningPhase == 0 || runningPhase == 3
            ? CGPoint(x: 5, y: 14)
            : CGPoint(x: 5.2, y: 11.4)
        let tailControl2 = runningPhase == 0 || runningPhase == 3
            ? CGPoint(x: 2, y: 10)
            : CGPoint(x: 1.8, y: 10.8)

        var tail = Path()
        tail.move(to: CGPoint(x: 11, y: 12 + bodyLift))
        tail.addCurve(
            to: tailTip,
            control1: tailControl1,
            control2: tailControl2
        )
        context.stroke(tail, with: outline, style: stroke)

        let body = Path(
            ellipseIn: CGRect(x: 9.5, y: 6 + bodyLift, width: 21, height: 12)
        )
        context.fill(body, with: .color(palette.base))
        context.stroke(body, with: outline, style: StrokeStyle(lineWidth: 1))

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

        let muzzle = Path(
            ellipseIn: CGRect(
                x: 29.4,
                y: 9.3 + bodyLift,
                width: 5.7,
                height: 4.5
            )
        )
        context.fill(muzzle, with: .color(Color.white.opacity(0.60)))

        for eyeX in [27.7, 33.3] {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: eyeX,
                        y: 7.1 + bodyLift,
                        width: 1.7,
                        height: 2.0
                    )
                ),
                with: .color(palette.eye)
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: eyeX + 0.55,
                        y: 7.35 + bodyLift,
                        width: 0.45,
                        height: 0.55
                    )
                ),
                with: .color(Color.white.opacity(0.92))
            )
        }

        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 31.65,
                    y: 10.25 + bodyLift,
                    width: 1.55,
                    height: 1.15
                )
            ),
            with: .color(pink)
        )

        var smile = Path()
        smile.move(to: CGPoint(x: 32.42, y: 11.35 + bodyLift))
        smile.addCurve(
            to: CGPoint(x: 31.45, y: 12.15 + bodyLift),
            control1: CGPoint(x: 32.2, y: 11.95 + bodyLift),
            control2: CGPoint(x: 31.75, y: 12.15 + bodyLift)
        )
        smile.move(to: CGPoint(x: 32.42, y: 11.35 + bodyLift))
        smile.addCurve(
            to: CGPoint(x: 33.4, y: 12.15 + bodyLift),
            control1: CGPoint(x: 32.65, y: 11.95 + bodyLift),
            control2: CGPoint(x: 33.1, y: 12.15 + bodyLift)
        )
        context.stroke(
            smile,
            with: .color(faceLine),
            style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
        )

        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: 26.2,
                    y: 10.65 + bodyLift,
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
                    y: 10.65 + bodyLift,
                    width: 1.8,
                    height: 1.2
                )
            ),
            with: .color(pink.opacity(0.48))
        )

        var whiskers = Path()
        whiskers.move(to: CGPoint(x: 29.5, y: 11.1 + bodyLift))
        whiskers.addLine(to: CGPoint(x: 26.3, y: 10.4 + bodyLift))
        whiskers.move(to: CGPoint(x: 29.5, y: 12.0 + bodyLift))
        whiskers.addLine(to: CGPoint(x: 26.2, y: 12.4 + bodyLift))
        whiskers.move(to: CGPoint(x: 35.0, y: 11.1 + bodyLift))
        whiskers.addLine(to: CGPoint(x: 38.4, y: 10.4 + bodyLift))
        whiskers.move(to: CGPoint(x: 35.0, y: 12.0 + bodyLift))
        whiskers.addLine(to: CGPoint(x: 38.5, y: 12.5 + bodyLift))
        context.stroke(
            whiskers,
            with: .color(faceLine.opacity(0.72)),
            style: StrokeStyle(lineWidth: 0.55, lineCap: .round)
        )

        let legPairs: [(CGPoint, CGPoint)] = isRunning
            ? runningLegPairs(phase: runningPhase, lift: bodyLift)
            : [
                (CGPoint(x: 15, y: 16), CGPoint(x: 14, y: 20)),
                (CGPoint(x: 20, y: 17), CGPoint(x: 20, y: 20)),
                (CGPoint(x: 25, y: 17), CGPoint(x: 25, y: 20)),
                (CGPoint(x: 30, y: 15.5), CGPoint(x: 30, y: 19.5)),
            ]
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
    static let line = Color(red: 0.93, green: 0.93, blue: 0.94)
    static let automaticFill = Color(red: 0.96, green: 0.96, blue: 0.965)
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
        do {
            let repository = try FilePlanRepository.appGroup()
            let source = try await repository.load()
            let updated = try TaptionWidgetCommandEngine.apply(
                command,
                to: source
            )
            try await repository.save(updated)
            command.appliedToSharedRepository = true
        } catch {
            command.appliedToSharedRepository = false
        }

        var payload = TaptionWidgetSharedStore.readPayload()
        if let index = payload.items.firstIndex(where: { $0.id == id }) {
            apply(action, to: &payload.items[index], in: payload)
            payload.generatedAt = .now
            try TaptionWidgetSharedStore.writePayload(payload)
        }
        try TaptionWidgetSharedStore.appendCommand(command)
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        return .result()
    }

    private func apply(
        _ action: TaptionWidgetCommandKind,
        to item: inout TaptionWidgetItem,
        in payload: TaptionWidgetPayload
    ) {
        switch action {
        case .complete, .stopCurrentActivity:
            item.status = "completed"
        case .postponeThirtyMinutes:
            item.startsAt = item.startsAt.addingTimeInterval(30 * 60)
            item.endsAt = item.endsAt.addingTimeInterval(30 * 60)
        case .moveToNextFreeTime:
            let duration = max(60, item.endsAt.timeIntervalSince(item.startsAt))
            let occupied = payload.items
                .filter { $0.id != item.id && !$0.isCompleted }
                .sorted { $0.startsAt < $1.startsAt }
            var candidate = max(Date.now, item.startsAt)
            for other in occupied {
                if candidate.addingTimeInterval(duration) <= other.startsAt {
                    break
                }
                if candidate < other.endsAt {
                    candidate = other.endsAt
                }
            }
            item.startsAt = candidate
            item.endsAt = candidate.addingTimeInterval(duration)
        }
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
#endif
