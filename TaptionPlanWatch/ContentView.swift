import SwiftUI

private struct WatchConfirmationSubject: Identifiable, Hashable {
    var id: String
    var suggestionID: UUID
    var sensorSessionID: UUID
    var behavior: WatchBehaviorKind
    var alternatives: [WatchBehaviorKind]
    var detail: String
    var pattern: WatchActivityPattern
    var startedAt: Date
    var endedAt: Date
}

/// Watch는 센서 원시자료를 iPhone으로 보내고, iPhone이 특정한 활동만
/// 사용자에게 확인받는다. 설정·계획·운동 제어는 iPhone이 맡는다.
struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    @State private var correctionSubject: WatchConfirmationSubject?
    @State private var acknowledgedSubjectID: String?
    @State private var acknowledgedLabel: String?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    dashboard(at: context.date)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Taption Plan")
            .task {
                WatchLaunchDiagnostics.mark("first-view-task")
                connectivity.prepare()
                WatchLaunchDiagnostics.mark("connectivity-prepared")
                workout.beginCaptureAfterFirstRender()
                WatchLaunchDiagnostics.mark("launch-complete")
            }
            .sheet(item: $correctionSubject) { subject in
                correctionList(for: subject)
            }
            .alert(
                "확인해 주세요",
                isPresented: Binding(
                    get: { workout.errorMessage != nil },
                    set: { if !$0 { workout.dismissError() } }
                )
            ) {
                Button("확인", role: .cancel) { workout.dismissError() }
            } message: {
                Text(workout.errorMessage ?? "")
            }
        }
    }

    private func dashboard(at date: Date) -> some View {
        let subject = confirmationSubject
        return VStack(alignment: .leading, spacing: 8) {
            transferCard(at: date)
            if let subject {
                confirmationCard(subject)
            } else {
                waitingCard
            }
        }
    }

    private var confirmationSubject: WatchConfirmationSubject? {
        guard let suggestion = connectivity.payload?.activitySuggestion,
              Date.now.timeIntervalSince(suggestion.endedAt) <= 2 * 3_600
        else { return nil }
        let percent = Int((suggestion.confidenceScore * 100).rounded())
        return WatchConfirmationSubject(
            id: suggestion.id.uuidString,
            suggestionID: suggestion.id,
            sensorSessionID: suggestion.sensorSessionID,
            behavior: suggestion.proposedBehavior,
            alternatives: suggestion.alternativeBehaviors,
            detail: suggestion.evidence.prefix(3).joined(separator: " · ")
                + " · \(percent)%",
            pattern: suggestion.pattern,
            startedAt: suggestion.startedAt,
            endedAt: suggestion.endedAt
        )
    }

    private func transferCard(at date: Date) -> some View {
        let measurement = workout.measurement
        let alerts = TaptionWatchAlertPolicy.alerts(for: measurement, now: date)
        return VStack(alignment: .leading, spacing: 7) {
            Button { connectivity.requestSync() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .foregroundStyle(.green)
                    Text("센서 수집 · iPhone 전송")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            statusRow("수집", value: collectionStatus(measurement))
            statusRow("전송", value: connectivity.statusText)
            statusRow("최근 측정", value: freshnessText(at: date))
            if let summary = connectivity.payload?.todaySummary {
                statusRow("일과", value: durationText(summary.recordedMinutes))
                statusRow("활동", value: durationText(summary.activeMinutes))
            }
            if workout.isActive {
                statusRow("원시 표본", value: "\(workout.sensorSampleCount)개")
            }
            if let alert = alerts.first {
                Label(alert.detail, systemImage: alert.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private func confirmationCard(_ subject: WatchConfirmationSubject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("활동 확인", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("\(subject.behavior.title) 맞나요?")
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(subject.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if acknowledgedSubjectID == subject.id, let acknowledgedLabel {
                Label(acknowledgedLabel, systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    Button { confirm(subject) } label: {
                        Text("맞아요")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button { correctionSubject = subject } label: {
                        Text("다른 활동")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.13),
            in: RoundedRectangle(cornerRadius: 15)
        )
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("확인할 활동 없음", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text("특정 가능한 활동이 생기면 여기에서 확인을 요청합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 15)
        )
    }

    private func correctionList(for subject: WatchConfirmationSubject) -> some View {
        NavigationStack {
            List {
                Section("실제로 무엇을 했나요?") {
                    ForEach(correctionOptions(for: subject), id: \.self) { kind in
                        Button { correct(subject, to: kind) } label: {
                            Label(kind.title, systemImage: symbol(for: kind))
                        }
                    }
                }
            }
            .navigationTitle("활동 선택")
        }
    }

    private func correctionOptions(
        for subject: WatchConfirmationSubject
    ) -> [WatchBehaviorKind] {
        (subject.alternatives + WatchBehaviorKind.confirmationChoices)
            .reduce(into: []) { result, kind in
                guard kind != subject.behavior, !result.contains(kind) else {
                    return
                }
                result.append(kind)
            }
    }

    private func confirm(_ subject: WatchConfirmationSubject) {
        sendConfirmation(subject, correctedBehavior: nil)
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = "확인했습니다"
    }

    private func correct(
        _ subject: WatchConfirmationSubject,
        to kind: WatchBehaviorKind
    ) {
        sendConfirmation(subject, correctedBehavior: kind)
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = "\(kind.title)(으)로 확인했습니다"
        correctionSubject = nil
    }

    private func sendConfirmation(
        _ subject: WatchConfirmationSubject,
        correctedBehavior: WatchBehaviorKind?
    ) {
        connectivity.sendActivityConfirmation(
            TaptionWatchActivityConfirmation(
                observedStartedAt: subject.startedAt,
                observedEndedAt: subject.endedAt,
                isCorrect: correctedBehavior == nil,
                observedBehavior: subject.behavior,
                correctedBehavior: correctedBehavior,
                suggestionID: subject.suggestionID,
                sensorSessionID: subject.sensorSessionID,
                pattern: subject.pattern
            )
        )
    }

    private func collectionStatus(
        _ measurement: TaptionWatchMeasurementSnapshot
    ) -> String {
        if workout.isActive { return "고정밀 수집 중" }
        guard let settings = workout.accelerationSettings else {
            return "iPhone 설정 대기"
        }
        guard settings.isEnabled else { return "꺼짐 · iPhone 설정" }
        if measurement.isMotionAccessDenied { return "동작 권한 없음" }
        guard measurement.isRecorderAvailable else { return "이 Watch에서 불가" }
        return settings.profile.displayName
    }

    private func freshnessText(at date: Date) -> String {
        guard let measuredAt = workout.measurement.measuredAt else {
            return "측정 없음"
        }
        let seconds = Int(max(0, date.timeIntervalSince(measuredAt)))
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        return "\(seconds / 3_600)시간 전"
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .font(.system(size: 10))
    }

    private func durationText(_ minutes: Int) -> String {
        let hours = max(0, minutes) / 60
        let remainder = max(0, minutes) % 60
        if hours == 0 { return "\(remainder)분" }
        if remainder == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(remainder)분"
    }

    private func symbol(for kind: WatchBehaviorKind) -> String {
        switch kind {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .stairsUp, .stairsDown: "figure.stairs"
        case .elevator: "arrow.up.arrow.down"
        case .automotive: "car.fill"
        case .publicTransit: "bus.fill"
        case .subway: "tram.fill"
        case .exercise: "dumbbell.fill"
        case .brushingTeeth: "mouth.fill"
        case .eating: "fork.knife"
        case .typing: "keyboard"
        case .housework: "house.fill"
        case .showering: "shower.fill"
        case .sleep: "bed.double.fill"
        case .lying: "bed.double"
        case .sitting: "chair.fill"
        case .standing: "figure.stand"
        case .stationary, .unknown: "pause.circle"
        }
    }
}
