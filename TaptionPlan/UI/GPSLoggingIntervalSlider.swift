import SwiftUI

/// 위치 확인 간격을 30초 단위로 고른다. 저장과 수집 재시작은 드래그가 끝날 때 한 번만 한다.
struct GPSLoggingIntervalSlider<Leading: View>: View {
    let seconds: Int
    let tint: Color
    let onCommit: (Int) -> Void
    @ViewBuilder let leading: () -> Leading

    /// 드래그 중 손잡이 위치. 스냅한 값을 되돌려 주면 손가락 이동량을 잃어 끝까지 가지 못한다.
    @State private var dragPosition: Double?
    @State private var isEditing = false

    /// 트랙 끝에서 손잡이 중심까지의 거리. iOS 26부터 손잡이가 넓다.
    private static var thumbInset: CGFloat {
        if #available(iOS 26, *) { 19 } else { 14 }
    }
    private var shownSeconds: Int {
        dragPosition.map(GPSLoggingPreferences.seconds(forSliderPosition:)) ?? seconds
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                leading()
                Text(GPSLoggingPreferences.intervalText(shownSeconds))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            Slider(
                value: Binding(
                    get: { dragPosition ?? GPSLoggingPreferences.sliderPosition(forSeconds: seconds) },
                    set: move
                ),
                in: 0...(GPSLoggingPreferences.majorTickPositions.last ?? 1),
                onEditingChanged: finishEditing
            )
            .tint(tint)
            .accessibilityLabel(AppLanguagePreference.text(korean: "위치 확인 간격", english: "Location check interval"))
            .accessibilityValue(GPSLoggingPreferences.intervalText(shownSeconds))
            .accessibilityAdjustableAction(adjust)
            ticks
        }
    }

    private var ticks: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - Self.thumbInset * 2
            let last = GPSLoggingPreferences.majorTickPositions.last ?? 1
            ForEach(GPSLoggingPreferences.majorTickSeconds.indices, id: \.self) { index in
                let position = GPSLoggingPreferences.majorTickPositions[index] / last
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 1, height: 5)
                    Text(GPSLoggingPreferences.intervalText(GPSLoggingPreferences.majorTickSeconds[index]))
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .position(x: Self.thumbInset + width * position, y: proxy.size.height / 2)
            }
        }
        .frame(height: TaptionType.scaled(TaptionType.snapped(22)))
        .accessibilityHidden(true)
    }

    private func move(to position: Double) {
        if isEditing {
            dragPosition = position
        } else {
            commit(GPSLoggingPreferences.seconds(forSliderPosition: position))
        }
    }

    private func commit(_ value: Int) {
        if value != seconds { onCommit(value) }
    }

    private func finishEditing(_ editing: Bool) {
        isEditing = editing
        guard !editing else { return }
        commit(shownSeconds)
        dragPosition = nil
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = GPSLoggingPreferences.intervalStepSeconds
        switch direction {
        case .increment: commit(GPSLoggingPreferences.clampedSeconds(seconds + step))
        case .decrement: commit(GPSLoggingPreferences.clampedSeconds(seconds - step))
        @unknown default: break
        }
    }
}
