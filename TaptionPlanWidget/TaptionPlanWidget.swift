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
    var animationPhase: Int = 0
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
        let horizon = now.addingTimeInterval(4 * 3_600)
        var refreshDates = (0...16).map {
            now.addingTimeInterval(Double($0) * 15 * 60)
        }
        if payload.hasRunningItem(at: now),
           payload.reducesMotion != true {
            refreshDates.append(
                contentsOf: (1...36).map {
                    now.addingTimeInterval(Double($0) * 5)
                }
            )
        }
        refreshDates.append(
            contentsOf: payload.items.flatMap { [$0.startsAt, $0.endsAt] }
                .filter { now < $0 && $0 < horizon }
        )
        let entries = Array(Set(refreshDates))
            .sorted()
            .map {
                TaptionScheduleEntry(
                    date: $0,
                    payload: payload,
                    animationPhase: Self.animationPhase(at: $0)
                )
            }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }

    private static func animationPhase(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 5) % 4
    }
}

private extension TaptionWidgetPayload {
    func hasRunningItem(at date: Date) -> Bool {
        items.contains {
            !$0.isCompleted && $0.startsAt <= date && date <= $0.endsAt
        }
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
        VStack(spacing: 0) {
            header

            PrototypeWidgetTrack(
                payload: entry.payload,
                date: entry.date,
                animationPhase: entry.animationPhase
            )
            .frame(height: 112)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .widgetURL(deepLinkURL)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("지금의 시간표")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetPalette.ink)

            Text(currentItem == nil ? "쉬는 중" : "집중 중")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(WidgetPalette.focusInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(WidgetPalette.focusFill, in: Capsule())
                .padding(.leading, 5)

            Link(destination: URL(string: "taptionplan://cats")!) {
                Text("\(catShortName) ▾")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WidgetPalette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white, in: Capsule())
                    .overlay {
                        Capsule().stroke(WidgetPalette.line)
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, 3)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                Image(systemName: weatherSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(weatherAndTimeLabel)
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(WidgetPalette.weather)
        }
        .frame(height: 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        icon: String,
        action: TaptionWidgetCommandKind
    ) -> some View {
        if let actionItem {
            Button(
                intent: TaptionWidgetActionIntent(
                    planID: actionItem.id.uuidString,
                    action: action
                )
            ) {
                actionLabel(title, icon: icon)
            }
            .buttonStyle(.plain)
        } else {
            actionLabel(title, icon: icon)
                .foregroundStyle(WidgetPalette.ink.opacity(0.42))
        }
    }

    private func actionLabel(
        _ title: String,
        icon: String
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(WidgetPalette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                WidgetPalette.actionFill,
                in: RoundedRectangle(cornerRadius: 10)
            )
    }

    private var visibleItems: [TaptionWidgetItem] {
        entry.payload.items
            .filter { !$0.isCompleted }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private var currentItem: TaptionWidgetItem? {
        visibleItems.first {
            $0.startsAt <= entry.date && entry.date <= $0.endsAt
        }
    }

    private var actionItem: TaptionWidgetItem? {
        let actionableItems = visibleItems.filter { !$0.isFixed }
        return actionableItems.first {
            $0.startsAt <= entry.date && entry.date <= $0.endsAt
        }
            ?? actionableItems.first(where: { entry.date < $0.startsAt })
            ?? actionableItems.last
    }

    private var catShortName: String {
        switch entry.payload.catStyle {
        case "white": "흰색"
        case "calico": "삼색"
        case "mackerel": "고등어"
        case "black": "검정"
        case "gray": "회색"
        case "cheese": "치즈"
        case "cow": "젖소무늬"
        default: "삼색"
        }
    }

    private var weatherSymbol: String {
        entry.payload.weatherSymbolName ?? "clock"
    }

    private var weatherAndTimeLabel: String {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        guard let temperature = entry.payload.temperatureCelsius else {
            return time
        }
        return "\(temperature.rounded().formatted())° · \(time)"
    }

    private var deepLinkURL: URL? {
        guard let item = actionItem else {
            return URL(string: "taptionplan://today")
        }
        return URL(string: "taptionplan://plan/\(item.id.uuidString)")
    }
}

private struct PrototypeWidgetTrack: View {
    let payload: TaptionWidgetPayload
    let date: Date
    let animationPhase: Int

    var body: some View {
        GeometryReader { proxy in
            let nowX = proxy.size.width / 2

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(WidgetPalette.line)
                    .frame(height: 1)

                Rectangle()
                    .fill(WidgetPalette.line)
                    .frame(height: 1)
                    .offset(y: 75)

                ForEach(trackItems) { item in
                    let start = fraction(item.startsAt)
                    let end = fraction(item.endsAt)
                    let width = max(
                        20,
                        proxy.size.width * max(0.02, end - start)
                    )
                    RoundedRectangle(cornerRadius: 7)
                        .fill(categoryColor(item))
                        .frame(width: width, height: 26)
                        .overlay(alignment: .leading) {
                            Text(item.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    WidgetPalette.ink.opacity(0.62)
                                )
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                        .offset(
                            x: proxy.size.width * start,
                            y: 40
                        )
                }

                Rectangle()
                    .fill(WidgetPalette.now)
                    .frame(width: 2, height: 41)
                    .offset(x: nowX - 1, y: 35)

                Circle()
                    .fill(WidgetPalette.now)
                    .frame(width: 8, height: 8)
                    .offset(x: nowX - 4, y: 32)

                WidgetCat(
                    style: payload.catStyle,
                    isRunning: currentItem != nil,
                    reducesMotion: payload.reducesMotion ?? false,
                    animationPhase: animationPhase
                )
                .frame(width: 40, height: 27)
                .offset(x: nowX - 20, y: 4)
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

    private var trackItems: [TaptionWidgetItem] {
        Array(
            payload.items
                .filter { !$0.isCompleted }
                .filter {
                    $0.startsAt < windowEnd && windowStart < $0.endsAt
                }
                .sorted { $0.startsAt < $1.startsAt }
                .prefix(2)
        )
    }

    private var currentItem: TaptionWidgetItem? {
        trackItems.first {
            $0.startsAt <= date && date <= $0.endsAt
        }
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

    private func categoryColor(_ item: TaptionWidgetItem) -> Color {
        if let hex = item.categoryHex {
            return Color(widgetHex: hex)
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
                drawSpeedLines(in: &context, phase: effectivePhase)
            }
            drawShadow(in: &context)
            drawCat(in: &context, phase: effectivePhase)
        }
        .accessibilityLabel(accessibilityName)
    }

    private func drawSpeedLines(
        in context: inout GraphicsContext,
        phase: Int
    ) {
        let offset = Double(phase % 2) * 2
        let opacity = phase % 2 == 0 ? 0.66 : 0.42
        let color = Color(red: 0.65, green: 0.65, blue: 0.68)
            .opacity(opacity)
        var longLine = Path()
        longLine.move(to: CGPoint(x: -offset, y: 10))
        longLine.addLine(to: CGPoint(x: 7 - offset, y: 10))
        context.stroke(
            longLine,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )

        var shortLine = Path()
        shortLine.move(to: CGPoint(x: 2 - offset, y: 16))
        shortLine.addLine(to: CGPoint(x: 6 - offset, y: 16))
        context.stroke(
            shortLine,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }

    private func drawShadow(in context: inout GraphicsContext) {
        context.fill(
            Path(ellipseIn: CGRect(x: 9, y: 23, width: 28, height: 3)),
            with: .color(.black.opacity(0.15))
        )
    }

    private func drawCat(in context: inout GraphicsContext, phase: Int) {
        let palette = CatPalette(style: style)
        let outline = GraphicsContext.Shading.color(palette.outline)
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

        let head = Path(
            ellipseIn: CGRect(x: 25.8, y: 4.3 + bodyLift, width: 10.4, height: 10.4)
        )
        context.fill(head, with: .color(palette.base))
        context.stroke(head, with: outline, style: StrokeStyle(lineWidth: 1))

        var ears = Path()
        ears.move(to: CGPoint(x: 27, y: 6 + bodyLift))
        ears.addLine(to: CGPoint(x: 27.5, y: 1 + bodyLift))
        ears.addLine(to: CGPoint(x: 31.5, y: 5.2 + bodyLift))
        ears.move(to: CGPoint(x: 32.5, y: 5.3 + bodyLift))
        ears.addLine(to: CGPoint(x: 36, y: 1 + bodyLift))
        ears.addLine(to: CGPoint(x: 36.5, y: 7 + bodyLift))
        context.fill(ears, with: .color(palette.base))
        context.stroke(ears, with: outline, style: stroke)

        context.fill(
            Path(ellipseIn: CGRect(x: 32.3, y: 8.3 + bodyLift, width: 1.4, height: 1.4)),
            with: .color(palette.eye)
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
    static let actionFill = Color(red: 0.93, green: 0.93, blue: 0.94)
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
