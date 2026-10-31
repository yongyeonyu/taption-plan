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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveActivityTitle(context.state))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(sensorCollectionKinds(context.state.collectionKinds))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .trailing) {
                            SensorCollectionWaveformView(state: context.state)
                                .frame(maxWidth: .infinity)
                            SensorCollectionSavedAtView(
                                lastSavedAt: context.state.lastSavedAt
                            )
                        }
                        SensorCollectionMeterRows(state: context.state)
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
                if let heartRate = state.latestHeartRate,
                   heartRate.isFinite, heartRate > 0, heartRate < 1000 {
                    Text("♥︎ \(Int(heartRate.rounded()))")
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

private struct SensorCollectionWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: SensorCollectionActivityAttributes.ContentState
    let positionOffset: Double
    let positionScale: Double
    let scanOffset: Double
    let scanScale: Double
    let showsIndicator: Bool

    init(
        state: SensorCollectionActivityAttributes.ContentState,
        positionOffset: Double = 0,
        positionScale: Double = 1,
        scanOffset: Double = 0,
        scanScale: Double = 1,
        showsIndicator: Bool = true
    ) {
        self.state = state
        self.positionOffset = positionOffset
        self.positionScale = positionScale
        self.scanOffset = scanOffset
        self.scanScale = scanScale
        self.showsIndicator = showsIndicator
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || !state.isCollecting
            )
        ) { timeline in
            waveform(at: timeline.date)
                .overlay {
                    scanline(at: timeline.date)
                }
        }
        .frame(minWidth: 24, maxWidth: .infinity)
        .frame(height: 14)
        .overlay(alignment: .topTrailing) {
            if state.isCollecting && showsIndicator {
                TimelineView(
                    .animation(minimumInterval: 1, paused: false)
                ) { timeline in
                    Circle()
                        .fill(.red)
                        .frame(width: 2, height: 2)
                        .opacity(
                            Int(timeline.date.timeIntervalSinceReferenceDate.rounded(.down)) % 2 == 0
                                ? 1
                                : 0
                        )
                }
                .frame(width: 2, height: 2)
                .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func waveform(at date: Date) -> some View {
        if state.phase == .hidden {
            Color.clear
        } else {
            ZStack {
                SensorCollectionFlatlineShape()
                    .stroke(
                        Color(red: 0.18, green: 0.72, blue: 0.59).opacity(0.38),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                if let progress = pulseProgress(at: date) {
                    SensorCollectionSamplePulseShape(
                        progress: reduceMotion ? 0.5 : progress,
                        positionOffset: positionOffset,
                        positionScale: positionScale
                    )
                    .stroke(
                        state.isExternalSample == true
                            ? .red
                            : Color(red: 0.18, green: 0.72, blue: 0.59),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func scanline(at date: Date) -> some View {
        if let progress = scanProgress(at: date) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(.black)
                    .frame(width: 7, height: 2)
                    .position(
                        x: CGFloat(
                            SensorCollectionWaveformMath.leftToRightEndpoint(
                                progress: progress,
                                width: Double(proxy.size.width)
                            )
                        ),
                        y: proxy.size.height / 2
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private func pulseProgress(at date: Date) -> Double? {
        guard state.isCollecting,
              state.phase == .pulse,
              state.phaseUntil.map({ date < $0 }) ?? true else {
            return nil
        }
        let halfWindow = SensorCollectionProgressPolicy
            .halfWindowDuration(intervalSeconds: state.intervalSeconds)
            ?? 0.5
        let origin = state.lastSavedAt ?? state.startedAt
        return SensorCollectionWaveformMath.cycleProgress(
            at: date,
            origin: origin,
            duration: halfWindow
        )
    }

    private func scanProgress(at date: Date) -> Double? {
        guard state.isCollecting else { return nil }
        let globalProgress = reduceMotion
            ? 0.5
            : SensorCollectionWaveformMath.cycleProgress(
                at: date,
                origin: state.waveformScanStartedAt ?? state.startedAt,
                duration: SensorCollectionActivityPolicy.waveformScanDuration
            )
        let scale = max(scanScale, 0.000_001)
        let localProgress = (globalProgress - scanOffset) / scale
        guard localProgress >= 0, localProgress <= 1 else { return nil }
        return localProgress
    }
}

private struct SensorCollectionFlatlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct SensorCollectionSamplePulseShape: Shape {
    var progress: Double
    var positionOffset: Double = 0
    var positionScale: Double = 1

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let localProgress = (progress - positionOffset) / max(positionScale, 0.000_001)
        guard localProgress >= 0, localProgress <= 1 else { return Path() }
        let sampleCount = max(24, Int((rect.width * 2).rounded(.up)))
        let baseline = rect.midY
        let verticalScale = rect.height * 0.42
        let pulseWidth = 0.34
        var path = Path()

        for index in 0...sampleCount {
            let position = Double(index) / Double(sampleCount)
            let x = rect.minX + rect.width * CGFloat(position)
            let pulsePhase = (position - localProgress) / pulseWidth + 0.5
            let signal = pulsePhase >= 0 && pulsePhase <= 1
                ? SensorCollectionWaveformMath.heartbeat(at: pulsePhase)
                : 0
            let y = baseline - CGFloat(signal) * verticalScale
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

private struct SensorCollectionMeterView: View {
    let mask: Int?
    let level: Double
    let color: Color

    init(mask: Int? = nil, level: Double = 0, color: Color) {
        self.mask = mask
        self.level = level
        self.color = color
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<10, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(isFilled(at: index) ? color : .white.opacity(0.22))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private func isFilled(at index: Int) -> Bool {
        if let mask {
            return mask & (1 << index) != 0
        }
        return Double(index) < level * 10
    }
}

private struct SensorCollectionMeterRows: View {
    let state: SensorCollectionActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(displayKinds.enumerated()), id: \.offset) { index, kind in
                HStack(spacing: 4) {
                    Text(SensorCollectionMeterModel.label(for: kind))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 42, alignment: .leading)
                    SensorCollectionMeterView(
                        mask: state.sensorMeterMasks?[kind],
                        level: SensorCollectionMeterModel.level(
                            mask: state.sensorMeterMasks?[kind]
                        ),
                        color: sensorCollectionMeterColor(
                            for: kind,
                            index: index,
                            state: state
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppLanguagePreference.text("센서별 최근 수신량", "Recent samples by sensor")
        )
    }

    private var displayKinds: [String] {
        let kinds = state.collectionKinds.filter { !$0.isEmpty }
        return kinds.isEmpty
            ? Array(SensorCollectionMeterModel.orderedKinds.prefix(6))
            : Array(kinds.prefix(6))
    }
}

private func sensorCollectionMeterColor(
    for kind: String,
    index: Int,
    state: SensorCollectionActivityAttributes.ContentState
) -> Color {
    switch SensorCollectionMeterModel.status(for: kind, state: state) {
    case .delayed: return .orange
    case .unavailable: return .red
    case .waiting: return .white.opacity(0.40)
    case .receiving:
        break
    }
    switch kind {
    case "location": return Color(red: 0.26, green: 0.61, blue: 1)
    case "motion", "steps": return Color(red: 0.22, green: 0.78, blue: 0.54)
    case "altitude": return Color(red: 0.62, green: 0.47, blue: 0.95)
    case "health": return .red
    case "wifi": return Color(red: 0.22, green: 0.72, blue: 0.86)
    default:
        let colors: [Color] = [.teal, .blue, .purple, .orange, .pink]
        return colors[index % colors.count]
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
                now: timeline.date
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
