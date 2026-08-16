import SwiftUI

struct MapHomeTimeSidebarActivity {
    let systemImage: String
    let tint: Color
    let accessibilityLabel: String
}

/// A narrow, non-resizing time rail for the map home screen.
/// The handle changes the selected minute only; it never changes panel size.
struct MapHomeTimeSidebar: View {
    let date: Date
    @Binding var selectedMinute: Int
    let activity: MapHomeTimeSidebarActivity?
    var onSelectionChanged: ((Int) -> Void)?
    var onSectionEdit: (() -> Void)?

    @State private var dragStartMinute: Int?
    @State private var lastRenderUptime: TimeInterval = 0

    private let railWidth: CGFloat
    // Keep the numeric rail visibly separated from both the map header and
    // the bottom ad boundary while preserving the same minute-to-pixel scale.
    private let verticalInset: CGFloat = 14
    private let activeRailWidth: CGFloat = 12
    private let numericColumnWidth: CGFloat = 27

    init(
        date: Date,
        selectedMinute: Binding<Int>,
        activity: MapHomeTimeSidebarActivity? = nil,
        railWidth: CGFloat = 58,
        onSelectionChanged: ((Int) -> Void)? = nil,
        onSectionEdit: (() -> Void)? = nil
    ) {
        self.date = date
        self._selectedMinute = selectedMinute
        self.activity = activity
        self.railWidth = max(58, railWidth)
        self.onSelectionChanged = onSelectionChanged
        self.onSectionEdit = onSectionEdit
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = max(220, proxy.size.height)
            let trackHeight = max(1, railHeight - verticalInset * 2)
            let maxMinute = MapHomeTimeSidebarMath.maximumSelectableMinute(
                for: date,
                now: Date()
            )
            let minute = min(max(selectedMinute, 0), maxMinute)
            let selectedY = verticalInset + trackHeight * CGFloat(minute) / 1439
            let trackX = railWidth - numericColumnWidth - activeRailWidth / 2 - 1
            let activeRailHeight = max(6, selectedY - verticalInset)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.68))
                    .frame(width: numericColumnWidth + 3, height: trackHeight)
                    .position(
                        x: railWidth - (numericColumnWidth + 3) / 2,
                        y: railHeight / 2
                    )
                    .allowsHitTesting(false)

                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.tpInk.opacity(0.72))
                    Rectangle()
                        .fill(Color.tpReferenceBlue.opacity(0.86))
                        .frame(height: activeRailHeight)
                }
                .frame(width: activeRailWidth, height: trackHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .position(
                        x: trackX,
                        y: verticalInset + trackHeight / 2
                    )

                ForEach(0...23, id: \.self) { hour in
                    let y = verticalInset + trackHeight * CGFloat(hour * 60) / 1439
                    HStack(spacing: 3) {
                        Capsule()
                            .fill(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.38 : 0.18))
                            .frame(width: hour.isMultiple(of: 6) ? 8 : 5, height: 1.5)
                        Text(String(format: "%02d", hour))
                            .font(.system(size: 8, weight: hour.isMultiple(of: 6) ? .bold : .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.82 : 0.52))
                            .frame(width: 16, alignment: .leading)
                    }
                    .frame(width: numericColumnWidth, alignment: .leading)
                    .position(
                        x: railWidth - numericColumnWidth / 2,
                        y: y
                    )
                }

                selectionHandle(
                    minute: minute,
                    y: selectedY,
                    trackX: trackX
                )
            }
            .frame(width: railWidth, height: railHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(
                dragGesture(trackHeight: trackHeight, maxMinute: maxMinute)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("시간 선택")
            .accessibilityValue(timeLabel(for: minute))
        }
        .frame(width: railWidth)
        .onDisappear {
            dragStartMinute = nil
        }
    }

    private func selectionHandle(
        minute: Int,
        y: CGFloat,
        trackX: CGFloat
    ) -> some View {
        ZStack {
            Button {
                onSectionEdit?()
            } label: {
                Image(systemName: activity?.systemImage ?? "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(activity?.tint ?? Color.tpReferenceMint)
                    .frame(width: 32, height: 32)
                    .background(
                        Color.tpInk.opacity(0.90),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                (activity?.tint ?? Color.tpReferenceMint)
                                    .opacity(0.45),
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activity?.accessibilityLabel ?? "활동 없음")
            .accessibilityHint("탭하면 섹션 편집을 엽니다")
            .position(x: trackX - 23, y: 20)

            Button {
                onSectionEdit?()
            } label: {
                VStack(spacing: -1) {
                    Text(String(format: "%02d", minute / 60))
                    Text(String(format: "%02d", minute % 60))
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 40)
                .background(
                    Color.tpInk.opacity(0.90),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("섹션 편집")
            .accessibilityValue(timeLabel(for: minute))
            .accessibilityHint("탭하면 이 시간의 섹션 편집을 엽니다")
            .position(x: trackX + activeRailWidth / 2 + 17, y: 20)
        }
        .frame(width: railWidth, height: 40)
        .position(x: railWidth / 2, y: y)
    }

    private func dragGesture(trackHeight: CGFloat, maxMinute: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartMinute == nil {
                    dragStartMinute = min(max(selectedMinute, 0), maxMinute)
                    lastRenderUptime = 0
                }
                let base = dragStartMinute ?? selectedMinute
                let minute = MapHomeTimeSidebarMath.minuteByDragging(
                    baseMinute: base,
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    maxMinute: maxMinute
                )
                publish(minute, force: false)
            }
            .onEnded { value in
                let base = dragStartMinute ?? selectedMinute
                let minute = MapHomeTimeSidebarMath.minuteByDragging(
                    baseMinute: base,
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    maxMinute: maxMinute
                )
                publish(minute, force: true)
                dragStartMinute = nil
            }
    }

    private func publish(_ minute: Int, force: Bool) {
        let resolved = min(max(minute, 0), MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date()))
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastRenderUptime,
            nowUptime: uptime,
            force: force
        ) else { return }
        guard selectedMinute != resolved else { return }
        selectedMinute = resolved
        onSelectionChanged?(resolved)
    }

    private func timeLabel(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

enum MapHomeTimeSidebarMath {
    static func maximumSelectableMinute(for date: Date, now: Date, calendar: Calendar = .current) -> Int {
        guard calendar.isDate(date, inSameDayAs: now) else { return 1439 }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return min(1439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    static func minuteByDragging(
        baseMinute: Int,
        translation: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int
    ) -> Int {
        guard trackHeight > 0 else { return min(max(baseMinute, 0), maxMinute) }
        let delta = Int((translation / trackHeight * 1439).rounded())
        return min(max(baseMinute + delta, 0), maxMinute)
    }
}
