import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityController
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        NavigationStack {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    dashboard(at: context.date)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
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

    private func dashboard(at date: Date) -> some View {
        let current = connectivity.currentItem(at: date)
        let next = connectivity.nextItem(at: date)
        return VStack(alignment: .leading, spacing: 8) {
            syncHeader
            WatchCatRunner(
                style: connectivity.payload?.catStyle ?? "calico",
                reducesMotion: connectivity.payload?.reducesMotion ?? false,
                isRunning: current != nil
            )
            quickWorkoutControls
            if let current {
                currentCard(current, at: date)
            } else {
                emptyCurrentCard
            }
            if workout.isActive {
                workoutMetrics(at: date)
            }
            if let next, next.id != current?.id {
                nextCard(next)
            } else {
                emptyNextCard
            }
            todaySummaryCard(at: date)
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

    private func matchingCurrentExercise(
        for kind: TaptionWatchWorkoutKind
    ) -> TaptionWatchPlanItem? {
        let now = Date.now
        let keyword = kind == .running ? "달리" : "걷"
        return connectivity.orderedItems
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
                Text("현재 진행")
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
                Text(categoryName)
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

    var body: some View {
        Group {
            if reducesMotion {
                track(at: Date(timeIntervalSinceReferenceDate: 0))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    track(at: context.date)
                }
            }
        }
        .frame(height: 30)
        .accessibilityLabel("작은 고양이 애니메이션")
    }

    private func track(at date: Date) -> some View {
        GeometryReader { proxy in
            let seconds = date.timeIntervalSinceReferenceDate
            let cycle = (seconds * 20).truncatingRemainder(
                dividingBy: proxy.size.width + 48
            )
            let x = isRunning ? cycle - 48 : (proxy.size.width - 48) / 2
            let gait = reducesMotion ? 0 : sin(seconds * 12)
            WatchCatFigure(style: style, gait: gait)
                .offset(
                    x: max(-48, min(proxy.size.width, x)),
                    y: isRunning ? abs(gait) * -1.5 : gait * 0.6
                )
        }
    }
}

private struct WatchCatFigure: View {
    let style: String
    let gait: Double

    private var palette: WatchCatPalette {
        WatchCatPalette(style: style)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(palette.base)
                .frame(width: 17, height: 4)
                .overlay(Capsule().stroke(palette.outline, lineWidth: 0.8))
                .rotationEffect(.degrees(-18 + gait * 12), anchor: .trailing)
                .offset(x: 0, y: 11)
            Capsule()
                .fill(palette.base)
                .frame(width: 30, height: 13)
                .overlay(Capsule().stroke(palette.outline, lineWidth: 0.8))
                .offset(x: 9, y: 8)
            Circle()
                .fill(palette.patch)
                .frame(width: 8, height: 7)
                .offset(x: 16, y: 10)
            Circle()
                .fill(palette.base)
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(palette.outline, lineWidth: 0.8))
                .offset(x: 34, y: 5)
            WatchCatEar()
                .fill(palette.base)
                .frame(width: 7, height: 7)
                .overlay(WatchCatEar().stroke(palette.outline, lineWidth: 0.7))
                .offset(x: 35, y: 2)
            WatchCatEar()
                .fill(palette.patch)
                .frame(width: 7, height: 7)
                .overlay(WatchCatEar().stroke(palette.outline, lineWidth: 0.7))
                .offset(x: 42, y: 2)
            Circle()
                .fill(palette.eye)
                .frame(width: 1.8, height: 1.8)
                .offset(x: 43, y: 10)
            Capsule()
                .fill(palette.base)
                .frame(width: 4, height: 9)
                .overlay(Capsule().stroke(palette.outline, lineWidth: 0.7))
                .rotationEffect(.degrees(gait * 15), anchor: .top)
                .offset(x: 17, y: 17)
            Capsule()
                .fill(palette.base)
                .frame(width: 4, height: 9)
                .overlay(Capsule().stroke(palette.outline, lineWidth: 0.7))
                .rotationEffect(.degrees(-gait * 15), anchor: .top)
                .offset(x: 32, y: 17)
        }
        .frame(width: 50, height: 28)
    }
}

private struct WatchCatEar: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct WatchCatPalette {
    let base: Color
    let patch: Color
    let outline: Color
    let eye: Color

    init(style: String) {
        switch style {
        case "white":
            base = Color(white: 0.98)
            patch = Color(white: 0.86)
            outline = Color(white: 0.62)
            eye = .blue
        case "mackerel":
            base = Color(red: 0.58, green: 0.60, blue: 0.62)
            patch = Color(red: 0.27, green: 0.29, blue: 0.31)
            outline = Color(red: 0.18, green: 0.19, blue: 0.20)
            eye = .yellow
        case "black":
            base = Color(white: 0.12)
            patch = Color(white: 0.28)
            outline = Color(white: 0.50)
            eye = .yellow
        case "gray":
            base = Color(white: 0.58)
            patch = Color(white: 0.43)
            outline = Color(white: 0.28)
            eye = .green
        case "cheese":
            base = Color(red: 0.92, green: 0.63, blue: 0.28)
            patch = Color(red: 0.72, green: 0.39, blue: 0.12)
            outline = Color(red: 0.48, green: 0.28, blue: 0.12)
            eye = .green
        case "cow":
            base = Color(white: 0.98)
            patch = Color(white: 0.10)
            outline = Color(white: 0.48)
            eye = .yellow
        default:
            base = Color(red: 0.96, green: 0.93, blue: 0.86)
            patch = Color(red: 0.86, green: 0.47, blue: 0.20)
            outline = Color(red: 0.35, green: 0.28, blue: 0.22)
            eye = .green
        }
    }
}
