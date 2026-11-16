import SwiftUI

struct TimeSliderScreen: View {
    @Binding var startAt: Date
    @Binding var durationMinutes: Int
    let onDone: () -> Void

    @State private var dragOriginSpan: TimeSpan?
    @State private var dragStartedAt: Date?
    @State private var previousFeedbackDate: Date?
    @State private var isPrecisionMode = false
    @State private var lastDragRenderUptime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("시간 선택", trailing: "완료", action: onDone)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: TaptionSpacing.regular) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.tpStudyDark).frame(width: 12, height: 12)
                    Text("영어 공부").font(.taption(size: 16, weight: .bold))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(timeRangeLabel)
                        .font(.taption(size: 24, weight: .black))
                    Spacer()
                    Text(durationLabel)
                        .font(.taption(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }

                GeometryReader { proxy in
                    let availableWidth = max(1, proxy.size.width - 12)
                    let lower =
                        xPosition(for: span.start, width: availableWidth) + 6
                    let upper =
                        xPosition(for: span.end, width: availableWidth) + 6
                    let barWidth = max(16, upper - lower)
                    ZStack {
                        RoundedRectangle(cornerRadius: TaptionRadius.card)
                            .fill(Color(red: 0.96, green: 0.96, blue: 0.97))
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 4) ? Color(red: 0.85, green: 0.85, blue: 0.87) : Color.tpTrackFill)
                                    .frame(width: 0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        RoundedRectangle(cornerRadius: TaptionRadius.field)
                            .fill(Color.tpStudy)
                            .frame(width: barWidth, height: 38)
                            .position(x: lower + barWidth / 2, y: 28)
                            .gesture(
                                dragGesture(.body, width: availableWidth)
                            )
                        sliderHandle
                            .position(x: lower, y: 28)
                            .gesture(
                                dragGesture(.start, width: availableWidth)
                            )
                        sliderHandle
                            .position(x: upper, y: 28)
                            .gesture(
                                dragGesture(.end, width: availableWidth)
                            )
                        Text(
                            span.start.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                            .font(.taption(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.field))
                            .position(
                                x: min(
                                    proxy.size.width - 31,
                                    max(31, lower)
                                ),
                                y: -5
                            )
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, 6)
                .padding(.top, 18)

                HStack {
                    ForEach(["00", "04", "08", "12", "16", "20", "24"], id: \.self) {
                        Text($0).frame(maxWidth: .infinity)
                    }
                }
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)

                HStack(spacing: TaptionSpacing.snug) {
                    ForEach([30, 60, 90, 120], id: \.self) { minutes in
                        Button {
                            durationMinutes = minutes
                        } label: {
                            Text(presetLabel(minutes))
                                .font(.taption(size: 9.5, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(
                                    durationMinutes == minutes
                                        ? Color.white : Color.tpSecondary
                                )
                                .background(
                                    durationMinutes == minutes
                                        ? Color.tpStudyDark
                                        : Color(
                                            red: 0.94,
                                            green: 0.94,
                                            blue: 0.95
                                        ),
                                    in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: TaptionSpacing.snug) {
                    hint("슬라이드", "1분 단위\n이동")
                    hint("빠르게", "10분 단위\n반올림 스냅")
                    hint(
                        "꾹 누르기",
                        isPrecisionMode
                            ? "정밀 조정\n사용 중"
                            : "정밀 조정\n1분 단위"
                    )
                }

                Button(action: onDone) {
                    Text("완료")
                        .font(.taption(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            Spacer()
        }
        .background(Color.tpCard)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sliderHandle: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white)
            .frame(width: 15, height: 30)
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .overlay {
                Capsule().fill(Color(red: 0.79, green: 0.79, blue: 0.81)).frame(width: 2.5, height: 14)
            }
    }

    private var span: TimeSpan {
        TimeSpan(
            start: startAt,
            end: startAt.addingTimeInterval(
                TimeInterval(max(1, durationMinutes) * 60)
            )
        )
    }

    private var dayBounds: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: startAt)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return TimeSpan(start: start, end: end)
    }

    private var timeRangeLabel: String {
        "\(span.start.formatted(date: .omitted, time: .shortened)) → \(span.end.formatted(date: .omitted, time: .shortened))"
    }

    private var durationLabel: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }

    private func presetLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)분" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)시간" }
        return "\(minutes / 60)시간 \(minutes % 60)분"
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(dayBounds.start)
            / max(1, dayBounds.duration)
        return width * CGFloat(max(0, min(1, fraction)))
    }

    private func dragGesture(
        _ handle: TimeSliderHandle,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let now = Date.now
                if dragOriginSpan == nil {
                    dragOriginSpan = span
                    dragStartedAt = now
                    previousFeedbackDate = handle == .end
                        ? span.end : span.start
                }
                guard let origin = dragOriginSpan,
                      let began = dragStartedAt else {
                    return
                }
                let elapsed = max(0.016, now.timeIntervalSince(began))
                let precision = elapsed >= 0.35
                if isPrecisionMode != precision {
                    isPrecisionMode = precision
                }
                let adjusted = adjustedSpan(
                    origin: origin,
                    translation: value.translation.width,
                    width: width,
                    began: began,
                    now: now,
                    handle: handle
                )
                if let previousFeedbackDate {
                    let current = handle == .end
                        ? adjusted.end : adjusted.start
                    if TimeSliderEngine.crossedTenMinuteTick(
                        previous: previousFeedbackDate,
                        current: current
                    ) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        self.previousFeedbackDate = current
                    }
                }
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastDragRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                apply(adjusted)
            }
            .onEnded { value in
                if let origin = dragOriginSpan,
                   let began = dragStartedAt {
                    let adjusted = adjustedSpan(
                        origin: origin,
                        translation: value.translation.width,
                        width: width,
                        began: began,
                        now: .now,
                        handle: handle
                    )
                    apply(adjusted)
                }
                dragOriginSpan = nil
                dragStartedAt = nil
                previousFeedbackDate = nil
                isPrecisionMode = false
                lastDragRenderUptime = 0
            }
    }

    private func adjustedSpan(
        origin: TimeSpan,
        translation: CGFloat,
        width: CGFloat,
        began: Date,
        now: Date,
        handle: TimeSliderHandle
    ) -> TimeSpan {
        let elapsed = max(0.016, now.timeIntervalSince(began))
        return TimeSliderEngine.adjust(
            origin,
            handle: handle,
            delta: Double(translation / max(1, width)) * dayBounds.duration,
            velocityPointsPerSecond: Double(translation) / elapsed,
            isLongPressPrecision: elapsed >= 0.35,
            bounds: dayBounds,
            minimumDuration: 10 * 60
        )
    }

    private func apply(_ adjusted: TimeSpan) {
        if startAt != adjusted.start {
            startAt = adjusted.start
        }
        let nextDuration = max(
            1,
            Int((adjusted.duration / 60).rounded())
        )
        if durationMinutes != nextDuration {
            durationMinutes = nextDuration
        }
    }

    private func hint(_ title: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.taption(size: 11, weight: .bold))
            Text(caption)
                .font(.taption(size: 9.5))
                .foregroundStyle(Color.tpSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97), in: RoundedRectangle(cornerRadius: TaptionRadius.compact))
    }
}

func pickerHeader(
    _ title: String,
    trailing: String,
    action: @escaping () -> Void
) -> some View {
    HStack {
        Text(title)
            .font(.taption(size: 19, weight: .bold))
        Spacer()
        Button(trailing, action: action)
            .font(.taption(size: 12, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(Color.tpCard)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
}
