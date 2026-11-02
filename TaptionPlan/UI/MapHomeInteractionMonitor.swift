import Foundation
import QuartzCore

/// 손짓별 끊김 계측(대표 지시 "터치·팝업·드래그 최적화", ARC1030A07).
///
/// 팝업·시트 열기, 사이드바 드래그, 지도 팬·핀치가 진행되는 동안 화면 틱 간격을 재서 `interaction_stats`로 남긴다.
/// 화면 틱이 늦은 만큼 메인 스레드가 막힌 것이라, 어느 손짓에서 몇 ms가 막히는지 실사용 기기 로그로 볼 수 있다.
/// 표시 링크는 측정 중에만 돌고, 값은 로그 정리에 걸리는 단어를 피해 적는다.
@MainActor
final class MapHomeInteractionMonitor {
    static let shared = MapHomeInteractionMonitor()

    private struct Phase {
        let name: String
        let startedAt: TimeInterval
        var lastTick: TimeInterval?
        var frames = 0
        var over12 = 0
        var over20 = 0
        var over40 = 0
        var over50 = 0
        var maximumMs = 0.0
        var firstMs: Double?
        /// 메인 스레드가 실제로 쓴 CPU 시간. 기기가 바빠도 흔들리지 않아 전후 비교에 쓴다(SHT1102A01).
        let startedCPU: Double
        var lastCPU: Double
        var maximumFrameCPUMs = 0.0
        /// 고정 길이 측정(시트 열기)이면 끝나는 시각. 손짓 측정이면 nil.
        let deadline: TimeInterval?
        /// 마지막 갱신 뒤 이 시간이 지나면 끝난다(지도 손짓처럼 끝을 알려 주지 않는 것).
        let idleTimeout: TimeInterval?
        var lastTouch: TimeInterval
    }

    private final class Ticker: NSObject {
        var onTick: ((CFTimeInterval) -> Void)?
        @objc func tick(_ link: CADisplayLink) { onTick?(link.timestamp) }
    }

    private var phases: [String: Phase] = [:]
    private var link: CADisplayLink?
    private let ticker = Ticker()

    func begin(_ name: String, duration: TimeInterval? = nil, idleTimeout: TimeInterval? = nil) {
        guard phases[name] == nil else { touch(name); return }
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Self.mainThreadCPUMs()
        phases[name] = Phase(
            name: name, startedAt: now, startedCPU: cpu, lastCPU: cpu, deadline: duration.map { now + $0 },
            idleTimeout: idleTimeout, lastTouch: now
        )
        startLinkIfNeeded()
    }

    /// 진행 중인 측정을 늘린다. 측정이 없으면 아무 일도 하지 않는다.
    func touch(_ name: String) {
        guard var phase = phases[name] else { return }
        phase.lastTouch = ProcessInfo.processInfo.systemUptime
        phases[name] = phase
    }

    func end(_ name: String) {
        guard let phase = phases.removeValue(forKey: name) else { return }
        record(phase)
        stopLinkIfIdle()
    }

    private func startLinkIfNeeded() {
        guard link == nil else { return }
        ticker.onTick = { [weak self] timestamp in self?.tick(timestamp) }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        // 시트가 움직이는 동안만 화면을 ProMotion 120Hz로 유지한다. 재는 동안 끝나면 다시 내려간다(SHT1102A01).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLinkIfIdle() {
        guard phases.isEmpty else { return }
        link?.invalidate()
        link = nil
    }

    private static func mainThreadCPUMs() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private func tick(_ timestamp: CFTimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Self.mainThreadCPUMs()
        var finished: [String] = []
        for name in phases.keys {
            guard var phase = phases[name] else { continue }
            if let last = phase.lastTick {
                let gap = (timestamp - last) * 1_000
                phase.frames += 1
                if gap > 12 { phase.over12 += 1 }
                if gap > 20 { phase.over20 += 1 }
                if gap > 40 { phase.over40 += 1 }
                if gap > 50 { phase.over50 += 1 }
                phase.maximumMs = max(phase.maximumMs, gap)
            } else {
                phase.firstMs = (now - phase.startedAt) * 1_000
            }
            phase.lastTick = timestamp
            phase.maximumFrameCPUMs = max(phase.maximumFrameCPUMs, cpu - phase.lastCPU)
            phase.lastCPU = cpu
            phases[name] = phase
            let expired = phase.deadline.map { now >= $0 } ?? false
            let idle = phase.idleTimeout.map { now - phase.lastTouch >= $0 } ?? false
            if expired || idle { finished.append(name) }
        }
        for name in finished { end(name) }
    }

    private func record(_ phase: Phase) {
        guard phase.frames > 0 || phase.firstMs != nil else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "interaction_stats",
            fields: ["name": phase.name],
            metrics: [
                "frames": Double(phase.frames), "over12": Double(phase.over12), "over20": Double(phase.over20),
                "over40": Double(phase.over40), "over50": Double(phase.over50),
                "max_ms": phase.maximumMs.rounded(), "first_ms": (phase.firstMs ?? -1).rounded(),
                "wall_ms": ((ProcessInfo.processInfo.systemUptime - phase.startedAt) * 1_000).rounded(),
                "cpu_ms": (phase.lastCPU - phase.startedCPU).rounded(),
                "max_frame_cpu_ms": phase.maximumFrameCPUMs.rounded(),
            ]
        )
    }
}

#if DEBUG || BENCH
/// 측정용: `-autoBenchSheets`면 지도가 뜬 뒤 하단 시트를 차례로 여닫아 상태를 바꾼 순간부터의 프레임 간격을 남긴다(SHT1102A01).
/// 첫 회(cold)는 시트를 처음 만드는 비용, 이후(warm)는 다시 여는 비용이다.
@MainActor
enum MapHomeSheetBench {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-autoBenchSheets") }

    static func run(selectDate: (Date) -> Void, sheets: [(name: String, set: (Bool) -> Void)]) async {
        // `-benchDaysAgo=4`면 그날을 고른 상태로 잰다(넣어 둔 원본이 있는 날).
        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-benchDaysAgo=") })?
            .dropFirst("-benchDaysAgo=".count), let days = Int(value),
           let date = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -days, to: .now) {
            try? await Task.sleep(for: .seconds(3))
            selectDate(date)
        }
        try? await Task.sleep(for: .seconds(25))
        // `-benchSheets=recording`이면 그 시트만 연다(표본 분석을 시트별로 나눈다).
        let only = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-benchSheets=") }
        for round in 0..<6 {
            for sheet in sheets where only?.contains(sheet.name) ?? true {
                MapHomeInteractionMonitor.shared.begin(
                    "bench_sheet_\(sheet.name)_\(round == 0 ? "cold" : "warm")", duration: 1.2
                )
                sheet.set(true)
                try? await Task.sleep(for: .seconds(1.6))
                sheet.set(false)
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
        TaptionPlanDiagnosticsLogger.shared.record("bench_sheets_done")
    }
}
#endif
