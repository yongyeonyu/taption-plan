import SwiftUI
import UIKit
import MapKit

#if DEBUG
/// Debug-only display-link probe for physical-device frame evidence.
///
/// Instruments can attach to the process, but on some iOS/Xcode combinations
/// it produces an empty trace package.  This probe stays out of release
/// builds and writes a small rolling summary to the app container instead.
/// It never participates in timeline state or layout calculations.
final class TimelineFrameBudgetProbe: NSObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var intervals: [Double] = []
    private var lastWriteAt = ProcessInfo.processInfo.systemUptime

    func start() {
        guard displayLink == nil else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        lastWriteAt = startedAt
        displayLink = CADisplayLink(
            target: self,
            selector: #selector(displayLinkTick(_:))
        )
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        writeSummary(force: true)
        lastTimestamp = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        if let lastTimestamp {
            let interval = link.timestamp - lastTimestamp
            if interval > 0, interval < 1 {
                intervals.append(interval)
                if intervals.count > 600 {
                    intervals.removeFirst(intervals.count - 600)
                }
            }
        }
        lastTimestamp = link.timestamp
        writeSummary(force: false)
    }

    private func writeSummary(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWriteAt >= 4 else { return }
        lastWriteAt = now
        guard !intervals.isEmpty else { return }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[
            min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        ]
        let nominal = 1.0 / 60.0
        let dropped = intervals.filter {
            $0 > nominal * 1.5
        }.count
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "elapsed": now - startedAt,
            "samples": intervals.count,
            "medianFrameMs": median * 1_000,
            "p95FrameMs": p95 * 1_000,
            "maxFrameMs": (sorted.last ?? 0) * 1_000,
            "droppedOver25ms": dropped,
        ]

        do {
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("TaptionLogs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent(
                "FrameBudget-debug.jsonl"
            )
            let line = try JSONSerialization.data(
                withJSONObject: payload,
                options: []
            )
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } else {
                var firstLine = line
                firstLine.append(0x0A)
                try firstLine.write(to: file)
            }
        } catch {
            // Diagnostics must never affect the timeline render path.
        }
    }
}

struct TimelineFrameBudgetProbeView: UIViewRepresentable {
    final class Coordinator {
        let probe = TimelineFrameBudgetProbe()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        if ProcessInfo.processInfo.environment[
            "TAPTION_TIMELINE_FRAME_PROBE"
        ] == "1" {
            context.coordinator.probe.start()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(
        _ uiView: UIView,
        coordinator: Coordinator
    ) {
        coordinator.probe.stop()
    }
}
#endif
