import ActivityKit
import SwiftUI
import TaptionPlanCore
import WidgetKit

struct SensorCollectionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(
            for: SensorCollectionActivityAttributes.self
        ) { context in
            SensorCollectionLockScreenView(context: context)
                .activityBackgroundTint(
                    Color(red: 0.08, green: 0.11, blue: 0.15)
                )
                .activitySystemActionForegroundColor(.white)
                .environment(
                    \.locale,
                    AppLanguagePreference.current.resolvedLanguage.locale
                )
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TaptionLiveActivityCat(categoryID: context.state.currentActivityCategoryID ?? "unconfirmed", title: context.state.currentActivityTitle ?? "확인 중", style: context.state.currentActivityCatStyle ?? "white", frame: context.state.currentActivityFrame ?? 0)
                        .frame(width: 31, height: 31)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(liveActivityTitle(context.state))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let summary = context.state.daySummary {
                        SensorCollectionDaySummaryView(summary: summary)
                    }
                }
            } compactLeading: {
                TaptionLiveActivityCat(
                    categoryID: context.state.currentActivityCategoryID ?? "unconfirmed",
                    title: context.state.currentActivityTitle ?? "확인 중",
                    style: context.state.currentActivityCatStyle ?? "white",
                    frame: context.state.currentActivityFrame ?? 0
                )
                .frame(width: 35, height: 29)
            } compactTrailing: {
                Text(liveActivityTitle(context.state))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            } minimal: {
                TaptionLiveActivityCat(categoryID: context.state.currentActivityCategoryID ?? "unconfirmed", title: context.state.currentActivityTitle ?? "확인 중", style: context.state.currentActivityCatStyle ?? "white", frame: context.state.currentActivityFrame ?? 0)
                    .frame(width: 29, height: 29)
            }
            .keylineTint(Color(red: 0.18, green: 0.72, blue: 0.59))
        }
    }
}

/// 다이나믹 아일랜드 펼침 화면의 오늘 요약. 위에 대분류 네 칸, 아래에 걸음·이동 거리.
private struct SensorCollectionDaySummaryView: View {
    let summary: SensorCollectionDaySummary

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                ForEach(summary.categories, id: \.id) { category in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(widgetHex: category.hex))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(category.title)
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 2)
                        Text(category.durationText)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
            }
            HStack(spacing: 12) {
                metric(
                    "figure.walk",
                    summary.steps.formatted(),
                    label: AppLanguagePreference.text("걸음", "Steps")
                )
                metric(
                    "point.topleft.down.to.point.bottomright.curvepath.fill",
                    summary.distanceText,
                    label: nil
                )
                Spacer(minLength: 0)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ systemImage: String, _ value: String, label: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel(label ?? "")
                .accessibilityHidden(label == nil)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct SensorCollectionCompactSensorIcon: View {
    let state: SensorCollectionActivityAttributes.ContentState

    var body: some View {
        if state.isCollecting {
            TaptionPlanAppIcon()
                .frame(width: 18, height: 18)
                .accessibilityLabel(AppLanguagePreference.text("센서 아이콘", "Sensor icon"))
        } else {
            Color.clear
                .frame(width: 18, height: 18)
        }
    }
}

private struct SensorCollectionCompactHeartRate: View {
    let state: SensorCollectionActivityAttributes.ContentState

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1, paused: !state.isCollecting)
        ) { timeline in
            if state.isCollecting,
               state.sensorHUDUntil.map({ timeline.date < $0 }) == true {
                // 빨간 심박은 외부 센서의 3분 안 값일 때만 보인다(REV1110A04).
                if let heart = SensorExternalHeartPolicy.text(
                    isExternalSample: state.isExternalSample,
                    heartRate: state.latestHeartRate,
                    updatedAt: state.heartRateUpdatedAt,
                    now: timeline.date
                ), let heartRate = state.latestHeartRate {
                    Text(heart)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .accessibilityLabel("\(Int(heartRate.rounded())) BPM")
                } else {
                    Text(AppLanguagePreference.text("♥︎ 대기", "♥︎ Waiting"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

private struct SensorCollectionLockScreenView: View {
    let context: ActivityViewContext<SensorCollectionActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            TaptionLiveActivityCat(
                categoryID: context.state.currentActivityCategoryID ?? "unconfirmed",
                title: context.state.currentActivityTitle ?? AppLanguagePreference.text("확인 중", "Checking"),
                style: context.state.currentActivityCatStyle ?? "white",
                frame: context.state.currentActivityFrame ?? 0
            )
            .frame(width: 57, height: 44)

            // 잠금 화면: 현재 활동 이름을 위에, 연봉 카운터(번 돈)를 아래에 보여 준다.
            VStack(alignment: .leading, spacing: 3) {
                Text(liveActivityTitle(context.state))
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                salaryLine(context.state)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                if let heart = SensorExternalHeartPolicy.text(
                    isExternalSample: context.state.isExternalSample,
                    heartRate: context.state.latestHeartRate,
                    updatedAt: context.state.heartRateUpdatedAt,
                    now: timeline.date
                ) {
                    Text(heart)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }

            SensorCollectionSavedAtView(
                lastSavedAt: context.state.lastSavedAt
            )
        }
        .foregroundStyle(.white)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            sensorCollectionAccessibilityLabel(for: context.state)
        )
        .widgetURL(URL(string: "taptionplan://sensor"))
    }
}

private struct TaptionPlanAppIcon: View {
    var body: some View {
        Image("SensorCollectionAppIcon")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .clipShape(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .accessibilityLabel(
                AppLanguagePreference.text("BOKKI Plan 앱 아이콘", "BOKKI Plan app icon")
            )
    }
}

private func sensorCollectionAccessibilityLabel(
    for state: SensorCollectionActivityAttributes.ContentState
) -> String {
    let kinds = sensorCollectionKinds(state.collectionKinds)
    let status: String
    switch state.phase {
    case .waiting:
        status = AppLanguagePreference.text("센서 정보 대기중", "Waiting for sensor data")
    case .pulse:
        status = AppLanguagePreference.text("센서 정보 저장중", "Saving sensor data")
    case .flatline:
        status = AppLanguagePreference.text("다음 센서 정보 대기중", "Waiting for the next sample")
    case .hidden:
        status = AppLanguagePreference.text("센서 수집 종료", "Sensor collection ended")
    }
    let activityTitle = liveActivityTitle(state)
    return "\(activityTitle), \(status), \(kinds)"
}

private struct SensorCollectionSavedAtView: View {
    let lastSavedAt: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(AppLanguagePreference.text("최근 저장", "Last saved"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
            if let lastSavedAt {
                Text(lastSavedAt, style: .timer)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(AppLanguagePreference.text("대기", "Waiting"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
        }
    }
}

/// 잠금 화면 연봉 줄. 기준값이 있으면 TimelineView로 간격마다 다시 그려 실시간으로 올라간다.
@ViewBuilder
private func salaryLine(_ state: SensorCollectionActivityAttributes.ContentState) -> some View {
    if let base = state.salaryBaseSeconds,
       let rate = state.salaryHourlyRate,
       let measuredAt = state.salaryMeasuredAt {
        let tick = state.salaryTickSeconds ?? 10
        TimelineView(.periodic(from: measuredAt, by: TimeInterval(max(1, tick)))) { timeline in
            Text(AppLanguagePreference.text("연봉 카운터 ", "Salary ") + SensorCollectionSalaryText.text(
                baseSeconds: base,
                hourlyRate: rate,
                measuredAt: measuredAt,
                isWorking: state.salaryIsWorking ?? false,
                tickSeconds: tick,
                now: timeline.date,
                currencyCode: state.salaryCurrencyCode
            ))
        }
    } else {
        Text(state.salaryText.map { AppLanguagePreference.text("연봉 카운터 \($0)", "Salary \($0)") }
             ?? sensorCollectionKinds(state.collectionKinds))
    }
}

private func sensorCollectionKinds(_ kinds: [String]) -> String {
    let labels = kinds.map { kind in
        switch kind {
        case "location": "GPS"
        case "motion": AppLanguagePreference.text("동작", "Motion")
        case "altitude": AppLanguagePreference.text("고도", "Altitude")
        case "steps": AppLanguagePreference.text("걸음", "Steps")
        case "health": AppLanguagePreference.text("건강", "Health")
        case "wifi": "Wi-Fi"
        default: kind
        }
    }
    return labels.isEmpty
        ? AppLanguagePreference.text("센서", "Sensors")
        : labels.joined(separator: " · ")
}

private func liveActivityTitle(
    _ state: SensorCollectionActivityAttributes.ContentState
) -> String {
    let action = TaptionLiveActivityStickmanAction.resolve(
        categoryID: state.currentActivityCategoryID ?? "unconfirmed",
        title: state.currentActivityTitle ?? ""
    )
    let localized = action.localizedTitle
    // 대분류로 풀리지 않는 사용자 정의 이름은 원래 제목을 그대로 쓴다.
    if action == .activity, let raw = state.currentActivityTitle, !raw.isEmpty,
       AppLanguagePreference.current.resolvedLanguage == .korean {
        return raw
    }
    return localized
}
