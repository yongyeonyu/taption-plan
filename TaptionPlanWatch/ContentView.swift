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

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    @State private var correctionSubject: WatchConfirmationSubject?
    @State private var acknowledgedSubjectID: String?
    @State private var acknowledgedLabel: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    dashboard(at: context.date)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .navigationTitle("Taption")
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
        let currentItems = connectivity.currentItems(at: date)
        let nextItems = Array(
            connectivity.upcomingItems(at: date).prefix(3)
        )
        let subject = subject(for: currentItems, at: date)
        return VStack(alignment: .leading, spacing: 8) {
            syncHeader
            confirmationCard(for: subject)
            WatchCatRunner(
                style: connectivity.payload?.catStyle ?? "calico",
                reducesMotion: connectivity.payload?.reducesMotion ?? false,
                isRunning: !currentItems.isEmpty
                    || workout.isActive
                    || (subject?.isMovement ?? false),
                date: date
            )
            if workout.isActive {
                workoutMetrics(at: date)
            }
            quickWorkoutControls
            if currentItems.isEmpty {
                emptyCurrentCard
            } else {
                currentSection(currentItems, at: date)
            }
            if nextItems.isEmpty {
                emptyNextCard
            } else {
                upcomingSection(nextItems)
            }
            todaySummaryCard(at: date)
            watchCollectionStatus
        }
    }

    // MARK: - 확인

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

    @ViewBuilder
    private func confirmationCard(
        for subject: WatchConfirmationSubject?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("지금 이거 맞나요?")
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

    // MARK: - 계획

    private func currentSection(
        _ items: [TaptionWatchPlanItem],
        at date: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("현재 진행")
                    .font(.caption.weight(.bold))
                Text("\(items.count)개")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text("동시 실행 가능")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                currentCard(item, at: date)
            }
        }
    }

    private func upcomingSection(
        _ items: [TaptionWatchPlanItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("다음 항목")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(items.count)개")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                nextCard(item)
            }
        }
    }

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

    private var watchCollectionStatus: some View {
        Group {
            if let settings = workout.accelerationSettings, settings.isEnabled {
                Text(
                    "아이폰 설정 · 가속도 "
                        + settings.profile.subtitle
                        + " · 데이터 "
                        + workout.dataSyncProfile.subtitle
                )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
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

    private func currentCard(
        _ item: TaptionWatchPlanItem,
        at date: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color(hex: item.categoryHex))
                    .frame(width: 7, height: 7)
                Text(item.isGoal ? "현재 목표" : "현재 진행")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text(timeRange(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            if let categoryName = item.categoryName {
                Text(item.isGoal ? "목표 · \(categoryName)" : categoryName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress(for: item, at: date))
                .tint(color(hex: item.categoryHex))
            Button {
                toggle(item)
            } label: {
                Label(
                    item.status == "running" ? "종료" : "시작",
                    systemImage: item.status == "running"
                        ? "stop.fill"
                        : "play.fill"
                )
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(item.status == "running" ? .red : .green)
        }
        .padding(10)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private var emptyCurrentCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("지금은 빈 시간")
                    .font(.headline)
                Text("다음 항목 전까지 여유가 있어요")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func nextCard(_ item: TaptionWatchPlanItem) -> some View {
        HStack(spacing: 9) {
            VStack(spacing: 1) {
                Text(item.startsAt, style: .time)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("다음 항목")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 2)
            Circle()
                .fill(color(hex: item.categoryHex))
                .frame(width: 8, height: 8)
        }
        .padding(9)
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var emptyNextCard: some View {
        Label("오늘 남은 항목이 없습니다", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(
                Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12)
            )
    }

    private func todaySummaryCard(at date: Date) -> some View {
        let summary = summary(at: date)
        return VStack(alignment: .leading, spacing: 7) {
            Label("오늘 활동 요약", systemImage: "chart.bar.fill")
                .font(.caption.weight(.semibold))
            HStack(spacing: 4) {
                summaryMetric(
                    "완료",
                    value: "\(summary.completedCount)/\(summary.scheduledCount)"
                )
                summaryMetric(
                    "기록",
                    value: compactDuration(summary.recordedMinutes)
                )
                summaryMetric(
                    "활동",
                    value: compactDuration(summary.activeMinutes)
                )
            }
        }
        .padding(9)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12)
        )
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

    private func toggle(_ item: TaptionWatchPlanItem) {
        if item.status == "running" {
            Task {
                if workout.isActive,
                   workout.linkedPlan?.id == item.id {
                    _ = await workout.stop()
                }
                connectivity.send(.stopCurrentActivity, for: item.id)
            }
            return
        }
        connectivity.send(.start, for: item.id)
        guard item.categoryID == "exercise" else { return }
        Task {
            _ = await workout.start(
                kind: workoutKind(for: item.title),
                linkedPlan: item
            )
        }
    }

    private func workoutKind(for title: String) -> TaptionWatchWorkoutKind {
        if title.contains("달리") || title.localizedCaseInsensitiveContains("run") {
            return .running
        }
        if title.contains("자전거") || title.localizedCaseInsensitiveContains("cycling") {
            return .cycling
        }
        return .walking
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

    private func progress(
        for item: TaptionWatchPlanItem,
        at date: Date
    ) -> Double {
        let start = item.actualStartedAt ?? item.startsAt
        let duration = max(1, item.endsAt.timeIntervalSince(start))
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    private func timeRange(for item: TaptionWatchPlanItem) -> String {
        "\(item.startsAt.formatted(date: .omitted, time: .shortened))–\(item.endsAt.formatted(date: .omitted, time: .shortened))"
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

    private func color(hex: String?) -> Color {
        guard let hex else { return .green }
        let clean = hex.trimmingCharacters(
            in: CharacterSet(charactersIn: "#")
        )
        guard let value = UInt64(clean, radix: 16), clean.count == 6 else {
            return .green
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct WatchCatRunner: View {
    let style: String
    let reducesMotion: Bool
    let isRunning: Bool
    let date: Date

    var body: some View {
        let action: TaptionCatAnimationAction = isRunning ? .walking : .sitting
        let pose = TaptionCatAnimationEngine.pose(
            at: date,
            preferredAction: action,
            reducesMotion: reducesMotion
        )
        TaptionCatAnimationView(
            style: style,
            pose: pose,
            reducesMotion: reducesMotion
        )
        .frame(height: 30)
        .accessibilityLabel("작은 고양이 애니메이션")
    }
}
