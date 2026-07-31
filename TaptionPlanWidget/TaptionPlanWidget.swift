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
        let horizon = now.addingTimeInterval(4 * 3_600)
        var refreshDates = (0...16).map {
            now.addingTimeInterval(Double($0) * 15 * 60)
        }
        refreshDates.append(
            contentsOf: payload.items.flatMap { [$0.startsAt, $0.endsAt] }
                .filter { now < $0 && $0 < horizon }
        )
        let entries = Array(Set(refreshDates))
            .sorted()
            .map { TaptionScheduleEntry(date: $0, payload: payload) }
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
        .description("계획과 현재 시간을 보고 바로 완료하거나 미룰 수 있습니다.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

private struct TaptionScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TaptionScheduleEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inlineAccessoryView
            case .accessoryCircular:
                circularAccessoryView
            case .accessoryRectangular:
                accessoryView
            case .systemSmall:
                compactView
            default:
                fullView
            }
        }
        .widgetURL(deepLinkURL)
    }

    private var inlineAccessoryView: some View {
        Text("Taption · \(currentItem?.title ?? visibleItems.first?.title ?? "다음 계획 없음")")
    }

    private var circularAccessoryView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let item = currentItem {
                ProgressView(
                    timerInterval: item.startsAt...item.endsAt,
                    countsDown: false
                ) {
                    WidgetCat(style: entry.payload.catStyle)
                        .frame(width: 22, height: 16)
                }
                .progressViewStyle(.circular)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3.bold())
            }
        }
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Taption", systemImage: "chart.bar.xaxis")
                .font(.caption2.bold())
            Text(currentItem?.title ?? "다음 계획 없음")
                .font(.caption)
                .lineLimit(1)
            if let currentItem {
                Text(currentItem.startsAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let item = currentItem ?? visibleItems.first {
                Text(item.title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(2)
                Text(item.startsAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(
                    intent: TaptionWidgetActionIntent(
                        planID: item.id.uuidString,
                        action: .complete
                    )
                ) {
                    Label("완료", systemImage: "checkmark")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
            } else {
                Spacer()
                Text("오늘 계획을 추가해 보세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var fullView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            WidgetTimeline(
                payload: entry.payload,
                date: entry.date,
                catStyle: entry.payload.catStyle,
                window: timelineWindow,
                rowLimit: rowLimit
            )
            .frame(maxHeight: .infinity)

            if let item = currentItem ?? visibleItems.first {
                HStack(spacing: 6) {
                    actionButton(
                        "완료",
                        icon: "checkmark",
                        item: item,
                        action: .complete
                    )
                    actionButton(
                        "30분",
                        icon: "clock.arrow.circlepath",
                        item: item,
                        action: .postponeThirtyMinutes
                    )
                    actionButton(
                        "빈 시간",
                        icon: "arrow.right.to.line",
                        item: item,
                        action: .moveToNextFreeTime
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("오늘", systemImage: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .black))
            Spacer()
            Text(entry.date, style: .time)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        }
    }

    private func actionButton(
        _ title: String,
        icon: String,
        item: TaptionWidgetItem,
        action: TaptionWidgetCommandKind
    ) -> some View {
        Button(
            intent: TaptionWidgetActionIntent(
                planID: item.id.uuidString,
                action: action
            )
        ) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.black)
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

    private var deepLinkURL: URL? {
        guard let item = currentItem ?? visibleItems.first else {
            return URL(string: "taptionplan://today")
        }
        return URL(string: "taptionplan://plan/\(item.id.uuidString)")
    }

    private var timelineWindow: WidgetTimelineWindow {
        switch family {
        case .systemMedium:
            .centered(hours: 6)
        case .systemExtraLarge:
            .week
        default:
            .day
        }
    }

    private var rowLimit: Int {
        switch family {
        case .systemMedium: 3
        case .systemLarge: 6
        case .systemExtraLarge: 8
        default: 4
        }
    }
}

private enum WidgetTimelineWindow {
    case centered(hours: Double)
    case day
    case week
}

private struct WidgetTimeline: View {
    let payload: TaptionWidgetPayload
    let date: Date
    let catStyle: String
    let window: WidgetTimelineWindow
    let rowLimit: Int

    var body: some View {
        GeometryReader { proxy in
            let headerWidth: CGFloat = 44
            let timelineWidth = max(1, proxy.size.width - headerWidth)
            let rows = Array(
                payload.items
                    .filter { !$0.isCompleted }
                    .filter {
                        $0.startsAt < windowEnd && windowStart < $0.endsAt
                    }
                    .sorted { $0.startsAt < $1.startsAt }
                    .prefix(rowLimit)
            )

            ZStack(alignment: .topLeading) {
                VStack(spacing: 3) {
                    ForEach(rows) { item in
                        HStack(spacing: 4) {
                            Text(categoryName(item.categoryID))
                                .font(.system(size: 8, weight: .semibold))
                                .lineLimit(1)
                                .frame(width: headerWidth, alignment: .leading)

                            GeometryReader { rowProxy in
                                let start = fraction(item.startsAt)
                                let end = fraction(item.endsAt)
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        categoryColor(item.categoryID)
                                            .opacity(item.endsAt < date ? 0.32 : 0.72)
                                    )
                                    .frame(
                                        width: max(
                                            18,
                                            rowProxy.size.width * max(0.02, end - start)
                                        )
                                    )
                                    .overlay(alignment: .leading) {
                                        Text(item.title)
                                            .font(.system(size: 8, weight: .bold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 5)
                                    }
                                    .offset(x: rowProxy.size.width * start)
                            }
                        }
                        .frame(height: 23)
                    }
                }

                let now = fraction(date)
                if 0...1 ~= now {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 1.5)
                        .offset(x: headerWidth + timelineWidth * now)

                    WidgetCat(style: catStyle)
                        .frame(width: 20, height: 14)
                        .offset(
                            x: headerWidth + timelineWidth * now - 10,
                            y: -5
                        )
                }
            }
        }
    }

    private func fraction(_ date: Date) -> CGFloat {
        let duration = windowEnd.timeIntervalSince(windowStart)
        guard duration > 0 else { return 0 }
        return CGFloat(
            min(
                1,
                max(
                    0,
                    date.timeIntervalSince(windowStart) / duration
                )
            )
        )
    }

    private var windowStart: Date {
        let calendar = Calendar.autoupdatingCurrent
        return switch window {
        case .centered(let hours):
            date.addingTimeInterval(-hours * 1_800)
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    private var windowEnd: Date {
        let calendar = Calendar.autoupdatingCurrent
        return switch window {
        case .centered(let hours):
            date.addingTimeInterval(hours * 1_800)
        case .day:
            calendar.date(byAdding: .day, value: 1, to: windowStart)
                ?? windowStart.addingTimeInterval(86_400)
        case .week:
            calendar.date(byAdding: .day, value: 7, to: windowStart)
                ?? windowStart.addingTimeInterval(7 * 86_400)
        }
    }

    private func categoryName(_ id: String) -> String {
        if let value = payload.items.first(where: {
            $0.categoryID == id
        })?.categoryName {
            return value
        }
        return switch id {
        case "movement": "이동"
        case "location": "위치"
        case "photo": "사진"
        case "exercise": "운동"
        case "study": "학습"
        case "hobby": "취미"
        case "sleep": "수면"
        case "routine": "생활"
        case "relationship": "관계"
        case "rest": "휴식"
        case "travel": "여행"
        case "health": "건강"
        default: "계획"
        }
    }

    private func categoryColor(_ id: String) -> Color {
        if let hex = payload.items.first(where: {
            $0.categoryID == id
        })?.categoryHex {
            return Color(widgetHex: hex)
        }
        return switch id {
        case "exercise": Color(red: 0.99, green: 0.73, blue: 0.68)
        case "study": Color(red: 0.72, green: 0.62, blue: 0.84)
        case "hobby": Color(red: 0.61, green: 0.83, blue: 0.73)
        case "sleep": Color(red: 0.55, green: 0.63, blue: 0.74)
        case "movement": Color(red: 0.77, green: 0.60, blue: 0.35)
        case "location": Color(red: 0.43, green: 0.69, blue: 0.82)
        case "travel": Color(red: 0.95, green: 0.56, blue: 0.40)
        default: Color(red: 0.47, green: 0.70, blue: 0.79)
        }
    }
}

private struct WidgetCat: View {
    let style: String

    var body: some View {
        ZStack {
            Capsule()
                .fill(baseColor)
                .frame(width: 14, height: 8)
                .overlay(Capsule().stroke(.black.opacity(0.7), lineWidth: 0.8))
            Circle()
                .fill(baseColor)
                .frame(width: 8, height: 8)
                .offset(x: 7, y: -2)
                .overlay(
                    Circle()
                        .fill(markColor)
                        .frame(width: 3, height: 3)
                        .offset(x: 8, y: -3)
                )
            Capsule()
                .fill(baseColor)
                .frame(width: 8, height: 2)
                .rotationEffect(.degrees(-38))
                .offset(x: -8, y: -3)
            ForEach([-4.0, 4.0], id: \.self) { x in
                Capsule()
                    .fill(.black.opacity(0.75))
                    .frame(width: 6, height: 1.4)
                    .rotationEffect(.degrees(x < 0 ? 18 : -18))
                    .offset(x: x, y: 5)
            }
        }
    }

    private var baseColor: Color {
        switch style {
        case "black": .black
        case "gray", "mackerel": .gray
        case "cheese": .orange
        default: .white
        }
    }

    private var markColor: Color {
        switch style {
        case "calico": .orange
        case "cow": .black
        case "mackerel": Color(red: 0.25, green: 0.27, blue: 0.30)
        case "cheese": Color(red: 0.66, green: 0.35, blue: 0.12)
        default: baseColor
        }
    }
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
                .activityBackgroundTint(.white)
                .activitySystemActionForegroundColor(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetCat(style: context.state.catStyle)
                        .frame(width: 24, height: 18)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        ProgressView(
                            timerInterval: context.state.startedAt...context.state.endsAt,
                            countsDown: false
                        )
                        .tint(.black)
                        Button(
                            intent: TaptionWidgetActionIntent(
                                planID: context.attributes.planID.uuidString,
                                action: .stopCurrentActivity
                            )
                        ) {
                            Image(systemName: "stop.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.black)
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
                Image(systemName: "chart.bar.xaxis")
            }
        }
    }
}

private struct TaptionLiveActivityLockScreenView: View {
    let context: ActivityViewContext<TaptionActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            WidgetCat(style: context.state.catStyle)
                .frame(width: 30, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                ProgressView(
                    timerInterval: context.state.startedAt...context.state.endsAt,
                    countsDown: false
                )
                .tint(.black)
            }
            Text(context.state.endsAt, style: .time)
                .font(.caption.bold())
            Button(
                intent: TaptionWidgetActionIntent(
                    planID: context.attributes.planID.uuidString,
                    action: .stopCurrentActivity
                )
            ) {
                Image(systemName: "stop.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
        }
        .padding()
        .widgetURL(
            URL(
                string:
                    "taptionplan://plan/\(context.attributes.planID.uuidString)"
            )
        )
    }
}
