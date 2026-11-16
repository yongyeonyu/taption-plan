import SwiftUI

struct MiniTimeSliceEditor: View {
    @Binding var startAt: Date
    @Binding var durationMinutes: Int
    let windowStart: Date
    let title: String
    let category: CategoryDefinition

    @State private var resizeOrigin: TimeSpan?
    @State private var moveOrigin: TimeSpan?
    @State private var isMoving = false
    @State private var lastGestureRenderUptime: TimeInterval = 0

    private let windowDuration: TimeInterval = 6 * 3_600

    var body: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            HStack(alignment: .firstTextBaseline) {
                Text("시간")
                    .font(.taption(size: 10.5, weight: .bold))
                Text("30분 기본 · 5분 단위 조정")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(timeRangeLabel)
                    .font(.taption(size: 10.5, weight: .bold))
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let lower = xPosition(for: span.start, width: width)
                let upper = xPosition(for: span.end, width: width)
                let barWidth = max(34, upper - lower)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: TaptionRadius.compact)
                        .fill(Color.tpFieldFill)

                    ForEach(0...12, id: \.self) { tick in
                        let x = width * CGFloat(tick) / 12
                        Rectangle()
                            .fill(Color.tpLine.opacity(tick.isMultiple(of: 2) ? 0.9 : 0.45))
                            .frame(width: tick.isMultiple(of: 2) ? 0.8 : 0.5, height: 70)
                            .position(x: x, y: 35)

                        if tick.isMultiple(of: 2), tick < 12 {
                            Text(tickLabel(tick))
                                .font(.taption(size: 8, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                                .position(x: min(width - 17, max(17, x)), y: 10)
                        }
                    }

                    RoundedRectangle(cornerRadius: TaptionRadius.control)
                        .fill(Color(hex: category.lightHex))
                        .overlay {
                            RoundedRectangle(cornerRadius: TaptionRadius.control)
                                .stroke(
                                    Color(hex: category.darkHex),
                                    lineWidth: isMoving ? 2.5 : 1.2
                                )
                        }
                        .frame(width: barWidth, height: 36)
                        .overlay(alignment: .center) {
                            Text(title)
                                .font(.taption(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                        }
                        .position(
                            x: min(width - barWidth / 2, lower + barWidth / 2),
                            y: 45
                        )
                        .contentShape(Rectangle())
                        .gesture(moveGesture(width: width))

                    sliderHandle
                        .position(x: lower, y: 45)
                        .gesture(resizeGesture(.start, width: width))
                    sliderHandle
                        .position(x: upper, y: 45)
                        .gesture(resizeGesture(.end, width: width))
                }
            }
            .frame(height: 70)

            HStack(spacing: TaptionSpacing.compact) {
                Image(systemName: "arrow.left.and.right")
                Text("양 끝 드래그: 5분 조정")
                Text("·")
                Image(systemName: "hand.tap")
                Text("막대를 꾹 누른 뒤 이동")
            }
            .font(.taption(size: 8.5, weight: .semibold))
            .foregroundStyle(isMoving ? Color.tpInk : Color.tpSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("미니 간트 시간 슬라이더")
    }

    private var sliderHandle: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.white)
            .frame(width: 15, height: 32)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .overlay {
                Capsule()
                    .fill(Color.tpSecondary.opacity(0.65))
                    .frame(width: 2.5, height: 14)
            }
            .contentShape(Rectangle().inset(by: -8))
    }

    private var span: TimeSpan {
        TimeSpan(
            start: startAt,
            end: startAt.addingTimeInterval(
                TimeInterval(max(5, durationMinutes) * 60)
            )
        )
    }

    private var windowBounds: TimeSpan {
        TimeSpan(
            start: windowStart,
            end: windowStart.addingTimeInterval(windowDuration)
        )
    }

    private var timeRangeLabel: String {
        "\(span.start.formatted(date: .omitted, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened)) · \(durationMinutes)분"
    }

    private func tickLabel(_ tick: Int) -> String {
        windowStart.addingTimeInterval(TimeInterval(tick) * 30 * 60)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(windowBounds.start)
            / max(1, windowBounds.duration)
        return width * CGFloat(max(0, min(1, fraction)))
    }

    private func resizeGesture(
        _ handle: TimeSliderHandle,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = span
                    lastGestureRenderUptime = 0
                }
                guard let origin = resizeOrigin else { return }
                applyGestureProjection(
                    resizedSpan(
                        origin: origin,
                        handle: handle,
                        translation: value.translation.width,
                        width: width
                    ),
                    force: false
                )
            }
            .onEnded { value in
                if let origin = resizeOrigin {
                    applyGestureProjection(
                        resizedSpan(
                            origin: origin,
                            handle: handle,
                            translation: value.translation.width,
                            width: width
                        ),
                        force: true
                    )
                }
                resizeOrigin = nil
                lastGestureRenderUptime = 0
            }
    }

    private func moveGesture(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !isMoving {
                        isMoving = true
                        UIImpactFeedbackGenerator(style: .medium)
                            .impactOccurred()
                    }
                case .second(true, let drag):
                    guard let drag else { return }
                    if moveOrigin == nil {
                        moveOrigin = span
                        lastGestureRenderUptime = 0
                    }
                    guard let origin = moveOrigin else { return }
                    applyGestureProjection(
                        movedSpan(
                            origin: origin,
                            translation: drag.translation.width,
                            width: width
                        ),
                        force: false
                    )
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag) = value,
                   let drag,
                   let origin = moveOrigin {
                    applyGestureProjection(
                        movedSpan(
                            origin: origin,
                            translation: drag.translation.width,
                            width: width
                        ),
                        force: true
                    )
                }
                moveOrigin = nil
                isMoving = false
                lastGestureRenderUptime = 0
            }
    }

    private func resizedSpan(
        origin: TimeSpan,
        handle: TimeSliderHandle,
        translation: CGFloat,
        width: CGFloat
    ) -> TimeSpan {
        TimeSliderEngine.adjust(
            origin,
            handle: handle,
            delta: Double(translation / max(1, width)) * windowDuration,
            snapInterval: QuickPlanDraftEngine.adjustmentStep,
            bounds: windowBounds,
            minimumDuration: QuickPlanDraftEngine.adjustmentStep
        )
    }

    private func movedSpan(
        origin: TimeSpan,
        translation: CGFloat,
        width: CGFloat
    ) -> TimeSpan {
        resizedSpan(
            origin: origin,
            handle: .body,
            translation: translation,
            width: width
        )
    }

    private func applyGestureProjection(
        _ adjusted: TimeSpan,
        force: Bool
    ) {
        if !force {
            guard TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastGestureRenderUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime
            ) else { return }
        }
        apply(adjusted)
    }

    private func apply(_ adjusted: TimeSpan) {
        if startAt != adjusted.start {
            startAt = adjusted.start
        }
        let nextDuration = max(
            5,
            Int((adjusted.duration / 60).rounded())
        )
        if durationMinutes != nextDuration {
            durationMinutes = nextDuration
        }
    }
}
