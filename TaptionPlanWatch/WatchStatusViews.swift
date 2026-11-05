import SwiftUI

/// 수집·전송 상태 한 줄. 눌러야 자세히 본다. 실제로 받은 값만 적는다.
struct WatchStatusLink: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    let date: Date
    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        let alert = TaptionWatchAlertPolicy.alerts(for: workout.measurement, now: date, language: language).first
        NavigationLink {
            WatchStatusDetail(language: language)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: alert?.symbolName ?? "waveform.path.ecg")
                    .foregroundStyle(alert == nil ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(alert?.detail ?? WatchStatusText.collection(workout: workout, language: language))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
            }
            .font(.caption2.weight(.semibold))
        }
    }
}

struct WatchStatusDetail: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    let language: AppLanguagePreference.ResolvedLanguage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                row(language.text("수집", "Collection"), WatchStatusText.collection(workout: workout, language: language))
                row(language.text("전송", "Transfer"), connectivity.statusText)
                row(language.text("최근 측정", "Last measurement"), freshnessText(at: context.date))
                if workout.isActive {
                    row(
                        language.text("원시 표본", "Raw samples"),
                        language.text("\(workout.sensorSampleCount)개", "\(workout.sensorSampleCount)")
                    )
                }
                Button { connectivity.requestSync() } label: {
                    Label(language.text("지금 보내기", "Send now"), systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle(language.text("수집 상태", "Collection status"))
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
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
