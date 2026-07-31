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
}

private struct TaptionWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaptionWatchWidgetEntry {
        TaptionWatchWidgetEntry(date: .now, payload: .widgetPlaceholder)
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
                    : TaptionWatchWidgetStore.read()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TaptionWatchWidgetEntry>) -> Void
    ) {
        let now = Date.now
        let horizon = now.addingTimeInterval(12 * 3_600)
        let payload = TaptionWatchWidgetStore.read()
        var dates = stride(
            from: now,
            through: horizon,
            by: 5 * 60
        ).map { $0 }
        dates.append(contentsOf: (payload?.items ?? []).flatMap {
            [$0.startsAt, $0.endsAt]
        })
        let entries = Array(Set(dates.filter { now <= $0 && $0 <= horizon }))
            .sorted()
            .map { TaptionWatchWidgetEntry(date: $0, payload: payload) }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }
}

private struct TaptionWatchStatusWidget: Widget {
    let kind = TaptionWatchWidgetKind.status

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaptionWatchWidgetProvider()) {
            TaptionWatchWidgetView(entry: $0)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Taption 지금")
        .description("현재 항목, 다음 항목과 오늘 활동을 표시합니다.")
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "cat.fill")
                    .font(.caption2.weight(.bold))
                Text(currentItem == nil ? "Taption Plan" : "지금")
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 2)
                Text(entry.date, style: .time)
                    .font(.caption2.monospacedDigit())
            }

            if let currentItem {
                HStack(spacing: 4) {
                    Image(systemName: symbol(for: currentItem))
                        .font(.caption.weight(.semibold))
                    Text(currentItem.title)
                        .font(.headline)
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 2)
                    Text(currentItem.endsAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                }
            } else {
                Text("현재 진행 중인 항목 없음")
                    .font(.headline)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                if let nextItem {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(nextItem.startsAt, style: .time)
                        .monospacedDigit()
                    Text(nextItem.title)
                        .lineLimit(1)
                        .privacySensitive()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                    Text("오늘 남은 항목 없음")
                }
                Spacer(minLength: 2)
            }
            .font(.caption2)

            HStack(spacing: 5) {
                Label(
                    "\(summary.completedCount)/\(summary.scheduledCount)",
                    systemImage: "checkmark"
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
    }

    private var circularView: some View {
        Gauge(value: progress) {
            Image(systemName: currentItem.map(symbol(for:)) ?? "cat.fill")
        } currentValueLabel: {
            Text("\(Int((progress * 100).rounded()))")
                .font(.caption2.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel(circularAccessibilityLabel)
    }

    private var inlineView: some View {
        Label {
            if let currentItem {
                Text("\(currentItem.title) · ~\(currentItem.endsAt, style: .time)")
                    .privacySensitive()
            } else if let nextItem {
                Text("다음 \(nextItem.startsAt, style: .time) · \(nextItem.title)")
                    .privacySensitive()
            } else {
                Text("오늘 일정 완료")
            }
        } icon: {
            Image(systemName: currentItem.map(symbol(for:)) ?? "cat.fill")
        }
    }

    private var items: [TaptionWatchPlanItem] {
        (entry.payload?.items ?? []).sorted { $0.startsAt < $1.startsAt }
    }

    private var currentItem: TaptionWatchPlanItem? {
        items.first { $0.status == "running" }
            ?? items.first {
                $0.status == "planned"
                    && $0.startsAt <= entry.date
                    && entry.date < $0.endsAt
            }
    }

    private var nextItem: TaptionWatchPlanItem? {
        let currentID = currentItem?.id
        return items.first {
            $0.id != currentID
                && $0.status == "planned"
                && entry.date < $0.endsAt
        }
    }

    private var summary: TaptionWatchDaySummary {
        entry.payload?.todaySummary
            ?? TaptionWatchDaySummary(
                date: entry.date,
                scheduledCount: items.count,
                completedCount: items.filter { $0.status == "completed" }.count,
                recordedMinutes: 0,
                activeMinutes: 0
            )
    }

    private var progress: Double {
        guard let currentItem else { return 0 }
        let duration = currentItem.endsAt.timeIntervalSince(currentItem.startsAt)
        guard duration > 0 else { return 0 }
        return min(
            1,
            max(0, entry.date.timeIntervalSince(currentItem.startsAt) / duration)
        )
    }

    private var circularAccessibilityLabel: String {
        guard let currentItem else { return "현재 진행 중인 항목 없음" }
        return "\(currentItem.title), \(Int((progress * 100).rounded()))퍼센트 진행"
    }

    private func symbol(for item: TaptionWatchPlanItem) -> String {
        switch item.categoryID {
        case "calendar": "calendar"
        case "location": "mappin.and.ellipse"
        case "movement": "arrow.triangle.swap"
        case "activity", "exercise": "figure.run"
        case "sleep": "bed.double.fill"
        case "learning", "study": "book.fill"
        case "travel": "airplane"
        default: "circle.fill"
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
                    startsAt: now.addingTimeInterval(-15 * 60),
                    endsAt: now.addingTimeInterval(45 * 60),
                    status: "planned",
                    actualStartedAt: nil,
                    categoryName: "프로젝트",
                    categoryHex: "7B57B2"
                ),
                TaptionWatchPlanItem(
                    id: UUID(),
                    title: "점심 이동",
                    categoryID: "movement",
                    startsAt: now.addingTimeInterval(60 * 60),
                    endsAt: now.addingTimeInterval(90 * 60),
                    status: "planned",
                    actualStartedAt: nil,
                    categoryName: "이동",
                    categoryHex: "AD813F"
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
