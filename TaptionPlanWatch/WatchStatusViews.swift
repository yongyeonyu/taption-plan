import SwiftUI
import WatchKit

/// 마지막 쪽. 수집·전송 상태와 고정밀 수집 중의 실제 값. 받은 값만 적는다.
/// 자주 바뀌는 수집 값은 이 쪽만 지켜본다.
struct WatchStatusPage: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let alert = TaptionWatchAlertPolicy.primary(
                        for: workout.measurement, now: context.date, language: language
                    ) {
                        alertCard(alert)
                    }
                    row(
                        language.text("수집", "Collection"),
                        WatchStatusText.collection(workout: workout, language: language),
                        symbol: "waveform.path.ecg"
                    )
                    if workout.isActive {
                        liveMetrics
                    }
                    row(language.text("전송", "Transfer"), connectivity.statusText, symbol: "iphone.and.arrow.forward")
                    row(
                        language.text("최근 측정", "Last measurement"),
                        freshnessText(at: context.date),
                        symbol: "clock"
                    )
                    Button {
                        connectivity.requestSync()
                        WKInterfaceDevice.current().play(.click)
                    } label: {
                        Label(language.text("지금 보내기", "Send now"), systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 6)
            }
        }
        .containerBackground(Color(white: 0.1).gradient, for: .tabView)
    }

    private func alertCard(_ alert: TaptionWatchAlert) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(alert.title, systemImage: alert.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(alert.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    /// 고정밀 수집(운동 세션) 중에 Watch가 실제로 받은 값. 0인 값은 아직 받지 못한 것이라 적지 않는다.
    private var liveMetrics: some View {
        HStack(spacing: 6) {
            if workout.heartRate > 0 {
                metric("heart.fill", .red, "\(Int(workout.heartRate.rounded()))", language.text("심박", "Heart rate"))
            }
            if workout.distanceMeters > 0 {
                metric(
                    "figure.walk", .green,
                    Measurement(value: workout.distanceMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)),
                    language.text("거리", "Distance")
                )
            }
            metric(
                "waveform", .blue,
                workout.sensorSampleCount.formatted(.number.notation(.compactName)),
                language.text("원시 표본", "Raw samples")
            )
        }
    }

    private func metric(_ symbol: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private func row(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.green)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func freshnessText(at date: Date) -> String {
        guard let measuredAt = workout.measurement.measuredAt else {
            return language.text("측정 없음", "No measurement")
        }
        let seconds = Int(max(0, date.timeIntervalSince(measuredAt)))
        if seconds < 60 { return language.text("방금", "Just now") }
        if seconds < 3_600 {
            return language.text("\(seconds / 60)분 전", "\(seconds / 60) min ago")
        }
        return language.text("\(seconds / 3_600)시간 전", "\(seconds / 3_600) hr ago")
    }
}

@MainActor
enum WatchStatusText {
    static func collection(workout: WatchWorkoutManager, language: AppLanguagePreference.ResolvedLanguage) -> String {
        let measurement = workout.measurement
        if workout.isActive { return language.text("고정밀 수집 중", "High-precision collection") }
        guard let settings = workout.accelerationSettings else {
            return language.text("iPhone 설정 대기", "Waiting for iPhone settings")
        }
        guard settings.isEnabled else { return language.text("꺼짐 · iPhone 설정", "Off · iPhone settings") }
        if measurement.isMotionAccessDenied {
            return language.text("동작 권한 없음", "Motion access unavailable")
        }
        guard measurement.isRecorderAvailable else {
            return language.text("이 Watch에서 불가", "Unavailable on this Watch")
        }
        return settings.profile.localizedDisplayName(language)
    }
}
