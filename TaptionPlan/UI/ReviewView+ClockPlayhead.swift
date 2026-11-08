import SwiftUI

extension ReviewView {
    // MARK: - 재생머리와 확대

    func updateCircularPlayhead(
        at location: CGPoint,
        in size: CGSize,
        force: Bool = false
    ) {
        if !circularPlayheadTracker.isDragging {
            circularPlayheadTracker.isDragging = true
            circularPlayheadTracker.lastPublishedUptime = 0
            if playStartedAt != nil { playStartedAt = nil }
            clearClockHighlight()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard force
            || circularPlayheadTracker.lastPublishedUptime == 0
            || now - circularPlayheadTracker.lastPublishedUptime >= 1.0 / 60.0
        else { return }
        circularPlayheadTracker.lastPublishedUptime = now
        setManualPlayhead(
            RecordClockEngine.clockFraction(
                x: Double(location.x),
                y: Double(location.y),
                centerX: Double(size.width / 2),
                centerY: Double(size.height / 2)
            )
        )
    }

    func finishCircularPlayheadDrag(
        at location: CGPoint,
        in size: CGSize
    ) {
        updateCircularPlayhead(at: location, in: size, force: true)
        circularPlayheadTracker.lastPublishedUptime = 0
        Task { @MainActor in
            await Task.yield()
            circularPlayheadTracker.isDragging = false
        }
    }

    func setManualPlayhead(_ fraction: Double) {
        let next = min(1, max(0, fraction))
        if circularPlayheadFraction.map({ abs($0 - next) > 0.00001 })
            != false {
            circularPlayheadFraction = next
        }
        if abs(linearPlayheadFraction - next) > 0.00001 {
            linearPlayheadFraction = next
        }
    }

    func clearManualPlayhead() {
        guard circularPlayheadFraction != nil else { return }
        circularPlayheadFraction = nil
        circularPlayheadTracker.lastPublishedUptime = 0
    }

    func adjustCircularPlayhead(
        _ direction: AccessibilityAdjustmentDirection
    ) {
        guard content.period.duration > 0 else { return }
        let current = clockPlaybackProgress(at: Date.now)
            ?? idleCircularPlayheadFraction(at: Date.now)
        let step = 15 * 60 / content.period.duration
        let offset: Double
        switch direction {
        case .increment: offset = step
        case .decrement: offset = -step
        @unknown default: return
        }
        if playStartedAt != nil { playStartedAt = nil }
        setManualPlayhead(ReviewClockGeometry.wrappedFraction(current + offset))
    }

    func circularPlayheadTimeText(_ fraction: Double) -> String {
        content.period.start
            .addingTimeInterval(content.period.duration * fraction)
            .formatted(date: .omitted, time: .shortened)
    }

    func updateClockZoom(factor: CGFloat) {
        if clockMagnifyOrigin == nil {
            clockMagnifyOrigin = clockZoomScale
            TaptionPlanDiagnosticsLogger.shared.record(
                "record_clock_zoom_began",
                fields: [
                    "factor": String(format: "%.3f", factor),
                    "scale": String(format: "%.3f", clockZoomScale),
                ]
            )
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastClockZoomRenderUptime == 0
            || now - lastClockZoomRenderUptime >= 1.0 / 60.0
        else { return }
        lastClockZoomRenderUptime = now
        guard let origin = clockMagnifyOrigin else { return }
        let next = ReviewClockGeometry.zoomScale(origin: origin, factor: factor)
        if next != clockZoomScale { clockZoomScale = next }
    }

    var clockMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                updateClockZoom(factor: CGFloat(value.magnification))
            }
            .onEnded { value in
                finishClockZoom(factor: CGFloat(value.magnification))
            }
    }

    func finishClockZoom(factor: CGFloat) {
        guard let origin = clockMagnifyOrigin else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "record_clock_zoom_ended_without_begin",
                fields: ["factor": String(format: "%.3f", factor)]
            )
            return
        }
        // 제스처 종료값은 프레임 게이트를 우회해 즉시 반영한다.
        let next = ReviewClockGeometry.zoomScale(origin: origin, factor: factor)
        if next != clockZoomScale { clockZoomScale = next }
        clockMagnifyOrigin = nil
        lastClockZoomRenderUptime = 0
        if clockZoomScale < Self.clockLinearThreshold {
            clockZoomScale = 1
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "record_clock_zoom_ended",
            fields: [
                "factor": String(format: "%.3f", factor),
                "scale": String(format: "%.3f", clockZoomScale),
                "linear": String(clockZoomScale >= Self.clockLinearThreshold),
            ]
        )
    }

    func resetClockZoom() {
        clockMagnifyOrigin = nil
        lastClockZoomRenderUptime = 0
        if clockZoomScale != 1 { clockZoomScale = 1 }
    }
}
