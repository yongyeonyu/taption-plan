import ActivityKit
import AppIntents
import SwiftUI
import TaptionPlanCore
import WidgetKit

struct TaptionPlanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaptionActivityAttributes.self) { context in
            TaptionLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(
                    Color(red: 0.08, green: 0.08, blue: 0.09)
                )
                .activitySystemActionForegroundColor(.white)
                .environment(
                    \.locale,
                    AppLanguagePreference.current.resolvedLanguage.locale
                )
        } dynamicIsland: { context in
            DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                VStack(alignment: .leading, spacing: 4) {
                    TaptionLiveActivityCat(
                        categoryID: context.state.compactActivityCategoryID ?? context.state.majorCategoryID,
                        title: context.state.compactActivityTitle ?? context.state.majorCategoryTitle,
                        style: context.state.catStyle,
                        frame: context.state.compactAnimationFrame ?? 0
                    )
                    .frame(width: 30, height: 27)
                    Text(context.state.compactActivityTitle ?? context.state.majorCategoryTitle)
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.90, green: 0.90, blue: 0.92))
                        .lineLimit(1)
                }
            }
            DynamicIslandExpandedRegion(.center) {
                Text(context.state.compactActivityTitle ?? context.state.majorCategoryTitle)
                    .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        ProgressView(
                            timerInterval: context.state.startedAt...max(context.state.startedAt, context.state.endsAt),
                            countsDown: false
                        )
                        .tint(Color(red: 0.48, green: 0.37, blue: 0.65))
                        Button(
                            intent: TaptionWidgetActionIntent(
                                planID: context.attributes.planID.uuidString,
                                action: .stopCurrentActivity
                            )
                        ) {
                            Text(AppLanguagePreference.text("종료", "Stop"))
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
                TaptionLiveActivityCat(
                    categoryID: context.state.compactActivityCategoryID ?? context.state.majorCategoryID,
                    title: context.state.compactActivityTitle ?? context.state.majorCategoryTitle,
                    style: context.state.catStyle,
                    frame: context.state.compactAnimationFrame ?? 0
                )
                .frame(width: 32, height: 26)
            } compactTrailing: {
                Text(context.state.compactActivityTitle ?? context.state.majorCategoryTitle)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            } minimal: {
                TaptionLiveActivityCat(
                        categoryID: context.state.compactActivityCategoryID ?? context.state.majorCategoryID,
                        title: context.state.compactActivityTitle ?? context.state.majorCategoryTitle,
                        style: context.state.catStyle,
                        frame: context.state.compactAnimationFrame ?? 0
                    )
                .frame(width: 26, height: 26)
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
                TaptionLiveActivityCat(
                    categoryID: context.state.compactActivityCategoryID ?? context.state.majorCategoryID,
                    title: context.state.compactActivityTitle ?? context.state.majorCategoryTitle,
                    style: context.state.catStyle,
                    frame: context.state.compactAnimationFrame ?? 0
                )
                .frame(width: 52, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.compactActivityTitle ?? context.state.majorCategoryTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.87, green: 0.87, blue: 0.88))
                        .lineLimit(1)
                    Text(context.state.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                Spacer()
                // 남은 시간은 시스템 타이머로 그려 갱신 없이 줄어든다(REV1110A04).
                Text(
                    timerInterval: context.state.startedAt...max(context.state.startedAt, context.state.endsAt),
                    countsDown: true
                )
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
                    .foregroundStyle(
                        Color(red: 0.78, green: 0.78, blue: 0.80)
                    )
            }

            ProgressView(
                timerInterval:
                    context.state.startedAt...max(context.state.startedAt, context.state.endsAt),
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
                    Text(AppLanguagePreference.text("종료", "End"))
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
