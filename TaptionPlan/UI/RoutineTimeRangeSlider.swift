import SwiftUI

/// Two-handle interval control used by routine details.  The striped track is
/// the plan and the solid track is the portion actually performed.
struct RoutineTimeRangeSlider: View {
    let plan: PlanRecord
    let actual: ActualRecord?
    let onCommit: (Date, Date) -> Void

    @State private var actualStart: Date
    @State private var actualEnd: Date
    @State private var lastHandleRenderUptime: TimeInterval = 0

    private let minimumDuration: TimeInterval = 5 * 60

    init(
        plan: PlanRecord,
        actual: ActualRecord?,
        onCommit: @escaping (Date, Date) -> Void
    ) {
        self.plan = plan
        self.actual = actual
        self.onCommit = onCommit
        let start = actual?.startedAt ?? plan.span.start
        _actualStart = State(initialValue: start)
        _actualEnd = State(
            initialValue: actual?.endedAt ?? start.addingTimeInterval(5 * 60)
        )
    }

    private var plannedDuration: TimeInterval { plan.span.duration }
    private var actualDuration: TimeInterval {
        max(0, actualEnd.timeIntervalSince(actualStart))
    }
    private var isLocked: Bool {
        actual.map(AutomaticRecordTimelineEngine.isImmutable) ?? false
    }
    private var progress: Double {
        guard plannedDuration > 0 else { return 0 }
        return min(1, actualDuration / plannedDuration)
    }
    private var status: (String, Color, String) {
        if actual == nil && actualDuration <= minimumDuration {
            return ("미완료", Color.tpSecondary, "circle")
        }
        if progress >= 0.999 {
            return ("완료", .green, "checkmark.circle.fill")
        }
        if actualDuration > 0 {
            return ("부분 달성", .orange, "circle.lefthalf.filled")
        }
        return ("미완료", Color.tpSecondary, "circle")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("계획 · \(timeRange(plan.span.start, plan.span.end))")
                Spacer(minLength: 4)
                Label(status.0, systemImage: status.2)
                    .foregroundStyle(status.1)
            }
            .font(.taption(size: 8, weight: .semibold))

            if isLocked {
                Label("자동 기록 · 수정 불가", systemImage: "lock.fill")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.tpLine.opacity(0.55))
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    Color.tpSecondary.opacity(0.22),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                )
                        }

                    Capsule()
                        .fill(PlanCategory(categoryID: plan.categoryID).darkColor.opacity(0.78))
                        .frame(width: actualWidth(width), height: 12)
                        .offset(x: actualX(width))

                    handleControl(
                        at: actualX(width),
                        isStart: true,
                        width: width
                    )
                    handleControl(
                        at: actualX(width) + actualWidth(width),
                        isStart: false,
                        width: width
                    )
                }
                .frame(height: 26)
            }
            .frame(height: 26)

            HStack(spacing: TaptionSpacing.tight) {
                Text("실제 · \(timeRange(actualStart, actualEnd))")
                Text("· \(durationText(actualDuration))")
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(isLocked ? "Apple 건강 기록" : "양끝을 드래그")
                    .foregroundStyle(Color.tpSecondary.opacity(0.82))
            }
            .font(.taption(size: 7.5, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
        .onChange(of: actual?.startedAt) { _, value in
            if let value { actualStart = value }
        }
        .onChange(of: actual?.endedAt) { _, value in
            if let value { actualEnd = value }
        }
    }

    private enum Handle { case start, end }

    private func handle(at x: CGFloat, isStart: Bool) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay {
                Circle().stroke(
                    PlanCategory(categoryID: plan.categoryID).darkColor,
                    lineWidth: 2
                )
            }
            .shadow(color: .black.opacity(0.14), radius: 2)
            .offset(x: x - 11)
            .accessibilityLabel(isStart ? "실제 시작 시간" : "실제 종료 시간")
    }

    @ViewBuilder
    private func handleControl(
        at x: CGFloat,
        isStart: Bool,
        width: CGFloat
    ) -> some View {
        if isLocked {
            handle(at: x, isStart: isStart)
                .opacity(0.42)
                .accessibilityHint("자동 기록은 수정할 수 없습니다")
        } else {
            handle(at: x, isStart: isStart)
                .gesture(handleGesture(isStart ? .start : .end, width: width))
        }
    }

    private func handleGesture(_ handle: Handle, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let date = date(at: value.location.x, width: width)
                let projected = projectedRange(for: handle, date: date)
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastHandleRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                if actualStart != projected.start {
                    actualStart = projected.start
                }
                if actualEnd != projected.end {
                    actualEnd = projected.end
                }
            }
            .onEnded { value in
                let projected = projectedRange(
                    for: handle,
                    date: date(at: value.location.x, width: width)
                )
                if actualStart != projected.start {
                    actualStart = projected.start
                }
                if actualEnd != projected.end {
                    actualEnd = projected.end
                }
                onCommit(projected.start, projected.end)
                lastHandleRenderUptime = 0
            }
    }

    private func projectedRange(
        for handle: Handle,
        date: Date
    ) -> (start: Date, end: Date) {
        switch handle {
        case .start:
            return (
                min(
                    max(plan.span.start, date),
                    actualEnd.addingTimeInterval(-minimumDuration)
                ),
                actualEnd
            )
        case .end:
            return (
                actualStart,
                max(
                    min(plan.span.end, date),
                    actualStart.addingTimeInterval(minimumDuration)
                )
            )
        }
    }

    private func fraction(_ date: Date) -> CGFloat {
        guard plannedDuration > 0 else { return 0 }
        return CGFloat(
            min(1, max(0, date.timeIntervalSince(plan.span.start) / plannedDuration))
        )
    }

    private func actualX(_ width: CGFloat) -> CGFloat { fraction(actualStart) * width }

    private func actualWidth(_ width: CGFloat) -> CGFloat {
        max(10, (fraction(actualEnd) - fraction(actualStart)) * width)
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
        let value = min(1, max(0, x / max(1, width)))
        return plan.span.start.addingTimeInterval(plannedDuration * value)
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func durationText(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}
