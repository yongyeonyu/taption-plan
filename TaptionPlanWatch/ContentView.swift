import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

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
            .task { workout.beginCaptureAfterFirstRender() }
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
        return VStack(alignment: .leading, spacing: 8) {
            syncHeader
            watchCollectionStatus
            WatchCatRunner(
                style: connectivity.payload?.catStyle ?? "calico",
                reducesMotion: connectivity.payload?.reducesMotion ?? false,
                isRunning: !currentItems.isEmpty
                    || workout.isActive
                    || workout.isMotionRecording,
                date: date
            )
            quickWorkoutControls
            if currentItems.isEmpty {
                emptyCurrentCard
            } else {
                currentSection(currentItems, at: date)
            }
            if workout.isActive {
                workoutMetrics(at: date)
            }
            if nextItems.isEmpty {
                emptyNextCard
            } else {
                upcomingSection(nextItems)
            }
            todaySummaryCard(at: date)
        }
    }

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
            } else if workout.isMotionRecording {
                Button(role: .destructive) {
                    workout.stopMotionRecording()
                } label: {
                    Label("가속도 기록 종료", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Text("손목 움직임을 저장하는 중 · (workout.archivedAccelerationSampleCount)개")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
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
                    Button {
                        _ = workout.startMotionRecording()
                    } label: {
                        Label("가속도", systemImage: "waveform.path.ecg")
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
