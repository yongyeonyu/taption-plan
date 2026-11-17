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
                    : groundTruthPayload().extendingOpenEndedItems(to: .now)
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
                    payload: payload.extendingOpenEndedItems(to: $0)
                )
            }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }

    private func groundTruthPayload(
        at date: Date = .now
    ) -> TaptionWidgetPayload {
        // 앱이 쓴 새 payload를 먼저 읽는다(REV1110A04).
        let payload = TaptionWidgetSharedStore.readWidgetPayload(now: date)
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
