import SwiftUI
import WatchKit

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
///
/// 세로로 넘기는 네 쪽이다: 지금 · 오늘 · 일정 · 상태. 이 화면은 iPhone 값만 지켜본다.
/// 심박·표본 수처럼 자주 바뀌는 수집 값은 상태 쪽만 지켜봐 다른 쪽을 다시 그리지 않는다.
struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    /// 지켜보지 않는다. 첫 화면에서 수집을 시작시키는 데만 쓴다.
    let workout: WatchWorkoutManager

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
            // 화면의 시간 글자는 시스템이 스스로 갱신한다. 여기서는 일정이 넘어가는 것만 분 단위로 본다.
            TimelineView(.everyMinute) { context in
                pages(at: context.date)
            }
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
            .modifier(WatchWorkoutErrorAlert(workout: workout, language: language))
        }
        .environment(\.locale, language.locale)
    }

    private func pages(at date: Date) -> some View {
        let payload = connectivity.payload
        let agenda = TaptionWatchFacePolicy.agenda(payload?.items ?? [], at: date)
        return TabView {
            if let subject = confirmationSubject(at: date) {
                confirmationPage(subject)
            }
            WatchNowPage(
                activity: payload?.currentActivity,
                hasPayload: payload != nil,
                catStyle: payload?.catStyle ?? "calico",
                next: agenda.first { $0.startsAt > date },
                language: language
            )
            .equatable()
            WatchTodayPage(
                summary: payload?.todaySummary.flatMap { $0.isCurrent(at: date) ? $0 : nil },
                date: date,
                language: language
            )
            .equatable()
            WatchAgendaPage(items: agenda, date: date, language: language)
                .equatable()
            WatchStatusPage(language: language)
        }
        .tabViewStyle(.verticalPage)
    }

    private func confirmationSubject(at date: Date) -> WatchConfirmationSubject? {
        guard let suggestion = TaptionWatchFacePolicy.activeSuggestion(connectivity.payload, at: date),
              let confirmationToken = suggestion.confirmationToken
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

    /// 확인할 활동이 있으면 맨 앞 쪽이 된다. 「맞아요」는 더블 탭으로도 누른다.
    private func confirmationPage(_ subject: WatchConfirmationSubject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: WatchBehaviorSymbol.name(for: subject.behavior))
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(
                        "\(subject.startedAt.formatted(date: .omitted, time: .shortened))–\(subject.endedAt.formatted(date: .omitted, time: .shortened))"
                    )
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
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
                    Button { confirm(subject) } label: {
                        Text(language.text("맞아요", "That's right"))
                            .font(.footnote.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .handGestureShortcut(.primaryAction)
                    Button { correctionSubject = subject } label: {
                        Text(language.text("다른 활동", "Another activity"))
                            .font(.footnote.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
            .padding(.horizontal, 6)
        }
        .containerBackground(Color.orange.opacity(0.35).gradient, for: .tabView)
    }

    private func correctionList(for subject: WatchConfirmationSubject) -> some View {
        NavigationStack {
            List {
                Section(language.text("실제로 무엇을 했나요?", "What did you actually do?")) {
                    ForEach(correctionOptions(for: subject), id: \.self) { kind in
                        Button { correct(subject, to: kind) } label: {
                            Label(
                                kind.localizedTitle(language),
                                systemImage: WatchBehaviorSymbol.name(for: kind)
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
        WKInterfaceDevice.current().play(.success)
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
        WKInterfaceDevice.current().play(.success)
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
}

enum WatchBehaviorSymbol {
    static func name(for kind: WatchBehaviorKind) -> String {
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

/// 수집 실패 알림. 수집 값을 지켜보는 것은 이 얇은 껍데기뿐이라 첫 화면 전체를 다시 그리지 않는다.
private struct WatchWorkoutErrorAlert: ViewModifier {
    @ObservedObject var workout: WatchWorkoutManager
    let language: AppLanguagePreference.ResolvedLanguage

    func body(content: Content) -> some View {
        content.alert(
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
}
