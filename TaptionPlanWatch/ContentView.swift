import SwiftUI

/// 워치 화면이 확인을 받는 대상. 진행 중인 계획이 있으면 계획이,
/// 없으면 센서가 마지막으로 추정한 행동이 대상이 된다.
private struct WatchConfirmationSubject: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var planID: UUID?
    var behavior: WatchBehaviorKind?
    var startedAt: Date
    var endedAt: Date

    var isMovement: Bool { behavior?.isMovement ?? false }
}

/// 워치 앱은 계속 들여다보는 화면이 아니다. 계획을 넘겨 보는 일은 iPhone이
/// 맡고, 이 화면은 "지금 무엇을 재고 있는지"와 "기록이 성한지"만 말한다.
struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    @State private var correctionSubject: WatchConfirmationSubject?
    @State private var acknowledgedSubjectID: String?
    @State private var acknowledgedLabel: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                // 고양이 애니메이션이 빠지면서 2Hz로 다시 그릴 이유가
                // 없어졌다. 남은 값은 초 단위 경과 시간뿐이다.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    dashboard(at: context.date)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .navigationTitle("센서")
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
                    set: { presented in
                        if !presented { workout.dismissError() }
                    }
                )
            ) {
                Button("확인", role: .cancel) {
                    workout.dismissError()
                }
            } message: {
                Text(workout.errorMessage ?? "")
            }
        }
    }

    private func dashboard(at date: Date) -> some View {
        let subject = subject(for: connectivity.currentItems(at: date), at: date)
        return VStack(alignment: .leading, spacing: 8) {
            syncHeader
            alertSection(at: date)
            measurementCard(for: subject, at: date)
            if workout.isActive {
                workoutMetrics(at: date)
            }
            quickWorkoutControls
            recordingStatusCard(at: date)
        }
    }

    // MARK: - 알림

    /// 알림 권한을 새로 요구하지 않는다. 워치가 이미 알고 있는 사실만
    /// 화면 맨 위에 올린다.
    @ViewBuilder
    private func alertSection(at date: Date) -> some View {
        let alerts = TaptionWatchAlertPolicy.alerts(
            for: workout.measurement,
            now: date
        )
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(alerts.prefix(2)) { alert in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: alert.symbolName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title)
                                .font(.caption.weight(.bold))
                            Text(alert.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(9)
            .background(
                Color.orange.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }

    // MARK: - 지금 재는 것

    private func subject(
        for currentItems: [TaptionWatchPlanItem],
        at date: Date
    ) -> WatchConfirmationSubject? {
        if let item = currentItems.first {
            return WatchConfirmationSubject(
                id: "plan-\(item.id.uuidString)",
                title: item.title,
                detail: item.categoryName.map { "계획 · \($0)" } ?? "계획",
                planID: item.id,
                behavior: nil,
                startedAt: item.actualStartedAt ?? item.startsAt,
                endedAt: min(date, item.endsAt)
            )
        }
        guard let observation = workout.latestObservation else { return nil }
        let percent = Int((observation.confidenceScore * 100).rounded())
        return WatchConfirmationSubject(
            id: "behavior-\(observation.behavior.rawValue)"
                + "-\(Int(observation.endedAt.timeIntervalSince1970))",
            title: observation.behavior.title,
            detail: "센서 추정 · \(percent)%",
            planID: nil,
            behavior: observation.behavior,
            startedAt: observation.startedAt,
            endedAt: observation.endedAt
        )
    }

    /// 무엇을 어떤 경로로 재고 있는지 먼저 말하고, 그 값이 맞는지 묻는다.
    /// 사용자의 대답은 iPhone이 학습·교정에 쓰는 유일한 라벨이다.
    @ViewBuilder
    private func measurementCard(
        for subject: WatchConfirmationSubject?,
        at date: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: sourceSymbolName)
                    .foregroundStyle(sourceTint)
                Text(workout.measurement.source.title)
                Spacer(minLength: 2)
                Text(freshnessText(at: date))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(subject?.title ?? "아직 모르겠어요")
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(subject?.detail ?? "손목 움직임을 더 모으는 중")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let acknowledgedLabel,
               acknowledgedSubjectID == subject?.id {
                Label(acknowledgedLabel, systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    if let subject {
                        Button {
                            confirm(subject)
                        } label: {
                            Label("맞아요", systemImage: "hand.thumbsup.fill")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    Button {
                        correctionSubject = subject ?? unknownSubject()
                    } label: {
                        Label(
                            subject == nil ? "알려주기" : "아니에요",
                            systemImage: "pencil"
                        )
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
            Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var sourceSymbolName: String {
        switch workout.measurement.source {
        case .workout: "figure.run.circle.fill"
        case .ambient: "waveform.path.ecg"
        case .idle: "pause.circle"
        }
    }

    private var sourceTint: Color {
        workout.measurement.source == .idle ? .secondary : .green
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

    private func unknownSubject() -> WatchConfirmationSubject {
        let now = Date.now
        return WatchConfirmationSubject(
            id: "unknown-\(Int(now.timeIntervalSince1970))",
            title: "아직 모르겠어요",
            detail: "직접 알려주기",
            planID: nil,
            behavior: nil,
            startedAt: now.addingTimeInterval(-5 * 60),
            endedAt: now
        )
    }

    private func correctionList(
        for subject: WatchConfirmationSubject
    ) -> some View {
        NavigationStack {
            List {
                Section("실제로 무엇을 했나요?") {
                    ForEach(Self.correctionOptions, id: \.self) { kind in
                        Button {
                            correct(subject, to: kind)
                        } label: {
                            Label(kind.title, systemImage: symbol(for: kind))
                                .font(.body)
                        }
                    }
                }
            }
            .navigationTitle("정정")
        }
    }

    /// 새 분류 체계를 만들지 않는다. 기존 `WatchBehaviorKind`에서 사용자가
    /// 고를 수 없는 "활동(unknown)"만 뺀 목록이다.
    private static let correctionOptions: [WatchBehaviorKind] =
        WatchBehaviorKind.allCases.filter { $0 != .unknown }

    private func symbol(for kind: WatchBehaviorKind) -> String {
        switch kind {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .stairsUp: "figure.stairs"
        case .stairsDown: "figure.stairs"
        case .elevator: "arrow.up.arrow.down"
        case .automotive: "car.fill"
        case .publicTransit: "bus.fill"
        case .subway: "tram.fill"
        case .exercise: "dumbbell.fill"
        case .brushingTeeth: "mouth.fill"
        case .eating: "fork.knife"
        case .typing: "keyboard"
        case .housework: "house.fill"
        case .sleep: "bed.double.fill"
        case .lying: "bed.double"
        case .sitting: "chair.fill"
        case .standing: "figure.stand"
        case .stationary, .unknown: "pause.circle"
        }
    }

    private func confirm(_ subject: WatchConfirmationSubject) {
        connectivity.sendActivityConfirmation(
            TaptionWatchActivityConfirmation(
                observedStartedAt: subject.startedAt,
                observedEndedAt: subject.endedAt,
                isCorrect: true,
                observedPlanID: subject.planID,
                observedPlanTitle: subject.planID == nil ? nil : subject.title,
                observedBehavior: subject.behavior
            )
        )
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = "고마워요"
    }

    private func correct(
        _ subject: WatchConfirmationSubject,
        to kind: WatchBehaviorKind
    ) {
        connectivity.sendActivityConfirmation(
            TaptionWatchActivityConfirmation(
                observedStartedAt: subject.startedAt,
                observedEndedAt: subject.endedAt,
                isCorrect: false,
                observedPlanID: subject.planID,
                observedPlanTitle: subject.planID == nil ? nil : subject.title,
                observedBehavior: subject.behavior,
                correctedBehavior: kind
            )
        )
        acknowledgedSubjectID = subject.id
        acknowledgedLabel = "\(kind.title)(으)로 바꿨어요"
        correctionSubject = nil
    }

    // MARK: - 측정 제어

    /// 운동 세션은 25Hz 가속도·자이로와 심박·경로를 함께 받는 유일한
    /// 경로다. 손목에서 이걸 켜고 끄는 것은 기록 자체에 필요하다.
    private var quickWorkoutControls: some View {
        Group {
            if workout.isActive {
                Button(role: .destructive) {
                    Task { _ = await workout.stop() }
                } label: {
                    Label("운동 종료", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                HStack(spacing: 5) {
                    Button {
                        Task {
                            _ = await workout.start(
                                kind: .walking,
                                linkedPlan: matchingCurrentExercise(
                                    for: .walking
                                )
                            )
                        }
                    } label: {
                        Label("걷기", systemImage: "figure.walk")
                    }
                    Button {
                        Task {
                            _ = await workout.start(
                                kind: .running,
                                linkedPlan: matchingCurrentExercise(
                                    for: .running
                                )
                            )
                        }
                    } label: {
                        Label("달리기", systemImage: "figure.run")
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption2.weight(.bold))
            }
        }
    }

    private func matchingCurrentExercise(
        for kind: TaptionWatchWorkoutKind
    ) -> TaptionWatchPlanItem? {
        let now = Date.now
        let keyword = kind == .running ? "달리" : "걷"
        return connectivity.currentItems(at: now)
            .filter {
                $0.startsAt <= now && now < $0.endsAt
                    && ["exercise", "activity", "movement"].contains($0.categoryID)
            }
            .sorted {
                let lhs = $0.title.contains(keyword)
                let rhs = $1.title.contains(keyword)
                return lhs && !rhs
            }
            .first
    }

    private var syncHeader: some View {
        Button {
            connectivity.requestSync()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(.green)
                Text(connectivity.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("iPhone과 지금 동기화")
    }

    private func workoutMetrics(at date: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: workout.workoutKind?.symbolName ?? "figure.run")
                .foregroundStyle(.green)
            Text(elapsedText(at: date))
                .font(.caption.weight(.bold))
                .monospacedDigit()
            Spacer(minLength: 2)
            Label(
                workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "—",
                systemImage: "heart.fill"
            )
            Label(distanceText, systemImage: "location.fill")
        }
        .font(.caption2)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color.green.opacity(0.13),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .accessibilityLabel("운동 센서 기록 중")
    }

    // MARK: - 기록 상태

    private func recordingStatusCard(at date: Date) -> some View {
        let measurement = workout.measurement
        let summary = summary(at: date)
        return VStack(alignment: .leading, spacing: 6) {
            Label("기록 상태", systemImage: "externaldrive.badge.timemachine")
                .font(.caption.weight(.semibold))
            statusRow(
                "배경 가속도",
                value: backgroundRecordingText(measurement)
            )
            statusRow("데이터 가져오기", value: workout.dataSyncProfile.subtitle)
            Button {
                connectivity.sendLocationTracking(
                    !(connectivity.payload?.locationTrackingEnabled ?? false)
                )
            } label: {
                HStack(spacing: 5) {
                    Image(
                        systemName: connectivity.payload?.locationTrackingEnabled == true
                            ? "location.fill"
                            : "location.slash"
                    )
                    Text("이동·위치 트래킹")
                    Spacer(minLength: 2)
                    Text(
                        connectivity.payload?.locationTrackingEnabled == true
                            ? "켬"
                            : "끔"
                    )
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if workout.isActive {
                statusRow(
                    "이번 세션 표본",
                    value: "\(workout.sensorSampleCount)개"
                )
            }
            if measurement.drainFailureCount > 0 {
                statusRow(
                    "읽지 못한 구간",
                    value: "\(measurement.drainFailureCount)회"
                )
            }
            HStack(spacing: 4) {
                summaryMetric(
                    "오늘 기록",
                    value: compactDuration(summary.recordedMinutes)
                )
                summaryMetric(
                    "활동",
                    value: compactDuration(summary.activeMinutes)
                )
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func backgroundRecordingText(
        _ measurement: TaptionWatchMeasurementSnapshot
    ) -> String {
        guard measurement.isRecordingRequested else { return "끔" }
        if measurement.isMotionAccessDenied { return "동작 권한 없음" }
        guard measurement.isRecorderAvailable else { return "이 워치에서 불가" }
        return workout.accelerationSettings?.profile.displayName ?? "켬"
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .font(.system(size: 10))
    }

    private func summary(at date: Date) -> TaptionWatchDaySummary {
        if let value = connectivity.payload?.todaySummary,
           Calendar.autoupdatingCurrent.isDate(value.date, inSameDayAs: date) {
            return value
        }
        let items = connectivity.orderedItems.filter {
            $0.status != "skipped"
                && Calendar.autoupdatingCurrent.isDate(
                    $0.startsAt,
                    inSameDayAs: date
                )
        }
        return TaptionWatchDaySummary(
            date: Calendar.autoupdatingCurrent.startOfDay(for: date),
            scheduledCount: items.count,
            completedCount: items.filter { $0.status == "completed" }.count,
            recordedMinutes: 0,
            activeMinutes: 0
        )
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(workout.startedAt ?? date)))
        return String(
            format: "%02d:%02d",
            seconds / 3_600,
            seconds / 60 % 60
        )
    }

    private var distanceText: String {
        if workout.distanceMeters >= 1_000 {
            return String(format: "%.1fkm", workout.distanceMeters / 1_000)
        }
        return "\(Int(workout.distanceMeters))m"
    }

    private func compactDuration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)분" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours)시간"
            : "\(hours)h \(remainder)m"
    }
}
