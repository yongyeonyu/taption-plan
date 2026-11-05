import SwiftUI

struct WatchConfirmationSubject: Identifiable, Hashable {
    var id: String
    var suggestionID: UUID
    var confirmationToken: UUID
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

    private var language: AppLanguagePreference.ResolvedLanguage {
        AppLanguagePreference.resolve(
            rawValue: connectivity.payload?.languagePreference
        )
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    dashboard(at: context.date)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("BOKKI Plan")
            .task {
                WatchLaunchDiagnostics.mark("first-view-task")
                connectivity.prepare()
                WatchLaunchDiagnostics.mark("connectivity-prepared")
                await workout.prepareHealthDataAccess()
                workout.beginCaptureAfterFirstRender()
                WatchLaunchDiagnostics.mark("launch-complete")
            }
            .sheet(item: $correctionSubject) { subject in
                correctionList(for: subject)
            }
            .alert(
                language.text("확인해 주세요", "Please check"),
                isPresented: Binding(
                    get: { workout.errorMessage != nil },
                    set: { if !$0 { workout.dismissError() } }
                )
            ) {
                Button(language.text("확인", "OK"), role: .cancel) {
                    workout.dismissError()
                }
            } message: {
                Text(workout.errorMessage ?? "")
            }
        }
        .environment(\.locale, language.locale)
    }

    private func dashboard(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WatchNowCard(activity: connectivity.payload?.currentActivity, hasPayload: connectivity.payload != nil, date: date, language: language)
            if let subject = confirmationSubject {
                confirmationCard(subject)
            }
            if let summary = connectivity.payload?.todaySummary {
                WatchTodayCard(summary: summary, language: language)
            }
            if let next = connectivity.orderedItems.nextPlan(after: date) {
                WatchNextCard(item: next, language: language)
            }
            WatchStatusLink(date: date, language: language)
        }
    }

    private var confirmationSubject: WatchConfirmationSubject? {
        guard let suggestion = connectivity.payload?.activitySuggestion,
              let confirmationToken = suggestion.confirmationToken,
              Date.now.timeIntervalSince(suggestion.endedAt) <= 2 * 3_600
        else { return nil }
        let percent = Int((suggestion.confidenceScore * 100).rounded())
        return WatchConfirmationSubject(
            id: suggestion.id.uuidString,
            suggestionID: suggestion.id,
            confirmationToken: confirmationToken,
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

    private func confirmationCard(_ subject: WatchConfirmationSubject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(language.text("활동 확인", "Confirm activity"), systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(language.text(
                "\(subject.behavior.localizedTitle(.korean)) 맞나요?",
                "Was this \(subject.behavior.localizedTitle(.english))?"
            ))
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
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
                        Text(language.text("맞아요", "That's right"))
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button { correctionSubject = subject } label: {
                        Text(language.text("다른 활동", "Another activity"))
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

    private func correctionList(for subject: WatchConfirmationSubject) -> some View {
        NavigationStack {
            List {
                Section(language.text("실제로 무엇을 했나요?", "What did you actually do?")) {
                    ForEach(correctionOptions(for: subject), id: \.self) { kind in
                        Button { correct(subject, to: kind) } label: {
                            Label(
                                kind.localizedTitle(language),
                                systemImage: symbol(for: kind)
                            )
                        }
                    }
                }
            }
            .navigationTitle(language.text("활동 선택", "Choose activity"))
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
        guard acknowledgedSubjectID != subject.id else { return }
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = language.text("확인했습니다", "Confirmed")
        sendConfirmation(subject, correctedBehavior: nil)
    }

    private func correct(
        _ subject: WatchConfirmationSubject,
        to kind: WatchBehaviorKind
    ) {
        guard acknowledgedSubjectID != subject.id else { return }
        sendConfirmation(subject, correctedBehavior: kind)
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = language.text(
            "\(kind.localizedTitle(.korean))(으)로 확인했습니다",
            "Confirmed as \(kind.localizedTitle(.english))"
        )
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
                confirmationToken: subject.confirmationToken,
                pattern: subject.pattern
            )
        )
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
