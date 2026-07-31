import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    connectionHeader
                    if workout.isActive {
                        activeWorkoutCard
                    } else {
                        scheduleCards
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Taption")
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

    private var connectionHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Text(connectivity.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var scheduleCards: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let current = connectivity.currentItem(at: context.date)
            let next = connectivity.nextItem(at: context.date)
            if let current {
                planCard(current, title: "지금", date: context.date, isCurrent: true)
            } else {
                ContentUnavailableView(
                    "진행 중인 계획 없음",
                    systemImage: "checkmark.circle",
                    description: Text("iPhone에서 계획을 추가해 주세요")
                )
            }
            if let next, next.id != current?.id {
                planCard(next, title: "다음", date: context.date, isCurrent: false)
            }
            workoutButtons(linkedPlan: current ?? next)
        }
    }

    private func planCard(
        _ item: TaptionWatchPlanItem,
        title: String,
        date: Date,
        isCurrent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isCurrent ? .green : .secondary)
                Spacer()
                Text(item.startsAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            ProgressView(value: progress(for: item, at: date))
                .tint(color(hex: item.categoryHex))
            HStack(spacing: 6) {
                if item.status == "running" {
                    actionButton("완료", symbol: "checkmark", color: .green) {
                        connectivity.send(.complete, for: item.id)
                    }
                } else {
                    actionButton("시작", symbol: "play.fill", color: .green) {
                        connectivity.send(.start, for: item.id)
                    }
                }
                actionButton("+30", symbol: "clock.arrow.circlepath", color: .orange) {
                    connectivity.send(.postponeThirtyMinutes, for: item.id)
                }
                actionButton("건너뜀", symbol: "forward.end.fill", color: .gray) {
                    connectivity.send(.skip, for: item.id)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    private func workoutButtons(linkedPlan: TaptionWatchPlanItem?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("운동 기록")
                .font(.caption.weight(.semibold))
            HStack(spacing: 7) {
                ForEach(TaptionWatchWorkoutKind.allCases, id: \.self) { kind in
                    Button {
                        Task {
                            let started = await workout.start(
                                kind: kind,
                                linkedPlan: linkedPlan
                            )
                            if started, let linkedPlan {
                                connectivity.send(.start, for: linkedPlan.id)
                            }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: kind.symbolName)
                            Text(kind.title)
                                .font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(kind == .running ? .orange : .green)
                }
            }
        }
    }

    private var activeWorkoutCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                Image(systemName: workout.workoutKind?.symbolName ?? "figure.run")
                    .font(.title)
                    .foregroundStyle(.green)
                Text(workout.workoutKind?.title ?? "운동")
                    .font(.headline)
                Text(elapsedText(at: context.date))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                HStack {
                    metric("심박", value: workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "—", unit: "BPM")
                    metric("거리", value: distanceText, unit: workout.distanceMeters >= 1_000 ? "KM" : "M")
                }
                Button(role: .destructive) {
                    Task {
                        if let plan = await workout.stop() {
                            connectivity.send(.stopCurrentActivity, for: plan.id)
                        }
                    }
                } label: {
                    Label("운동 종료", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(10)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 8))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
            Text(unit).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func progress(for item: TaptionWatchPlanItem, at date: Date) -> Double {
        let start = item.actualStartedAt ?? item.startsAt
        let duration = max(1, item.endsAt.timeIntervalSince(start))
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(workout.startedAt ?? date)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }

    private var distanceText: String {
        if workout.distanceMeters >= 1_000 {
            return String(format: "%.2f", workout.distanceMeters / 1_000)
        }
        return "\(Int(workout.distanceMeters))"
    }

    private func color(hex: String?) -> Color {
        guard let hex else { return .green }
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
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
