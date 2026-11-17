import Foundation
import QuartzCore
import UIKit

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
        #if DEBUG || BENCH
        if MapHomePerfBench.isRequested {
            MapHomePerfBench.emit(phase.name, [
                "frames": Double(phase.frames), "over20": Double(phase.over20), "over40": Double(phase.over40),
                "max_ms": phase.maximumMs, "first_ms": phase.firstMs ?? -1,
                "wall_ms": (ProcessInfo.processInfo.systemUptime - phase.startedAt) * 1_000,
                "cpu_ms": phase.lastCPU - phase.startedCPU, "max_frame_cpu_ms": phase.maximumFrameCPUMs,
            ])
        }
        #endif
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
/// 측정용: `-autoBenchLedgerScroll`이면 가계부를 열고 목록을 일정한 속도로 굴리며 프레임 간격을 남긴다(LGS1115A01).
/// 기록이 적으면 보기 기록을 넣었다가 끝나면 지운다. 시뮬레이터 Debug에서만 쓴다.
@MainActor
enum LedgerScrollBench {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-autoBenchLedgerScroll") }
    private static let marker = "bench-LGS1115A01"

    private static var started = false

    static func run() async {
        guard !started else { return }
        started = true
        try? await Task.sleep(for: .seconds(8))
        let book = LedgerBook.shared
        await book.load()
        let monthStart = Calendar.autoupdatingCurrent.dateInterval(of: .month, for: .now)?.start ?? .now
        let titles = ["점심 식당", "모퉁이 카페 라떼", "가상고속도로 통행료", "마트 장보기", "택시", "서점", "약국", "주유소"]
        var seeded: [UUID] = []
        for index in 0..<300 {
            var entry = LedgerEntry(occurredAt: min(.now, monthStart.addingTimeInterval(Double(index) * 2.3 * 3_600)), amount: Double(1_000 + index * 37), title: titles[index % titles.count])
            entry.category = LedgerCategory.allCases[index % LedgerCategory.allCases.count]
            entry.note = marker
            if index % 3 == 0 { entry.source = .message }
            seeded.append(await book.save(entry).id)
        }
        print("LGSBENCH opening")
        try? await Task.sleep(for: .seconds(1))
        LedgerPresenter.shared.isPresented = true
        try? await Task.sleep(for: .seconds(4))
        MapHomeInteractionMonitor.shared.begin("bench_ledger_scroll_idle")
        try? await Task.sleep(for: .seconds(4))
        MapHomeInteractionMonitor.shared.end("bench_ledger_scroll_idle")
        let speed = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-ledgerBenchSpeed=") }.flatMap { Double($0.dropFirst("-ledgerBenchSpeed=".count)) } ?? 1_800
        for round in ["cold", "warm", "warm2"] {
            guard let scroll = listScrollView() else { print("LGSBENCH no scroll view"); break }
            let top = -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            try? await Task.sleep(for: .seconds(1))
            let limit = scroll.contentSize.height - scroll.bounds.height
            MapHomeInteractionMonitor.shared.begin("bench_ledger_scroll_\(round)")
            let began = CACurrentMediaTime()
            // 초당 1,800pt로 4초: 손가락으로 빠르게 굴리는 정도.
            while CACurrentMediaTime() - began < 4 {
                let y = min(limit, top + (CACurrentMediaTime() - began) * speed)
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(4))
            }
            MapHomeInteractionMonitor.shared.end("bench_ledger_scroll_\(round)")
            try? await Task.sleep(for: .seconds(1))
        }
        LedgerPresenter.shared.isPresented = false
        // 닫은 뒤 홈이 따라잡는 구간도 잰다. 바깥 스크립트가 이 줄을 보고 화면을 찍는다.
        print("LGSBENCH closed")
        MapHomeInteractionMonitor.shared.begin("bench_ledger_after_close")
        try? await Task.sleep(for: .seconds(5))
        MapHomeInteractionMonitor.shared.end("bench_ledger_after_close")
        for id in seeded { await book.delete(id) }
        print("LGSBENCH done")
    }

    private static func listScrollView() -> UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            var controller = window.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            if let view = controller?.view, let found = find(view) { return found }
        }
        return nil
    }
}

/// 측정용: `-autoBenchPerf`면 첫 화면 → 대기 → 날짜 바꾸기 → 시간 끌기 → 지도 밀기 → 가계부·여행 열기를 차례로 돌리고
/// 숫자만 `PRFBENCH` 줄로 찍는다(PRF1116A01). 기록 내용·좌표는 찍지 않는다.
@MainActor
enum MapHomePerfBench {
    struct Actions {
        let isReady: () -> Bool
        let selectDaysAgo: (Int) -> Void
        let isDayLoaded: () -> Bool
        let dayRowCount: () -> Int
        let setMinute: (Int?) -> Void
        let setScrubbing: (Bool) -> Void
        let setLedger: (Bool) -> Void
        let setTravel: (Bool) -> Void
    }

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-autoBenchPerf") }

    static func run(_ actions: Actions) async {
        await waitUntil(timeout: 60, actions.isReady)
        // 열 상태(0 보통 · 1 약간 · 2 심함 · 3 위험)를 같이 남긴다. 앞 측정의 열기로 CPU가 느려진 회차를 가린다(PRF1117A01).
        emit("launch", [
            "ready_ms": sinceProcessStartMs(), "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue),
            "main_cpu_ms": mainCPUMs(), "all_cpu_ms": processCPUMs(),
        ])
        await waitUntil(timeout: 30, actions.isDayLoaded)
        emit("launch", ["day_loaded_ms": sinceProcessStartMs(), "rows": Double(actions.dayRowCount())])
        // `-benchLaunchOnly`: 콜드 실행만 잰다(PRF1117A01). 늦게 닫히는 시작 게이트까지 받으려고 잠깐 기다린다.
        if ProcessInfo.processInfo.arguments.contains("-benchLaunchOnly") {
            try? await Task.sleep(for: .seconds(3))
            print("PRFBENCH done")
            return
        }
        try? await Task.sleep(for: .seconds(25))
        for round in 0..<3 {
            let main = mainCPUMs(), all = processCPUMs()
            try? await Task.sleep(for: .seconds(10))
            emit("idle", ["round": Double(round), "main_cpu_ms": mainCPUMs() - main, "all_cpu_ms": processCPUMs() - all, "footprint_mb": footprintMB().now])
        }
        // 날짜 바꾸기: 처음 여는 날 셋(-1·-2·-3), 다시 여는 날 셋.
        for (index, days) in [1, 2, 3, 1, 2, 3].enumerated() {
            let name = "date_\(index < 3 ? "cold" : "warm")"
            let began = ProcessInfo.processInfo.systemUptime, main = mainCPUMs()
            MapHomeInteractionMonitor.shared.begin("bench_\(name)", duration: 3)
            actions.selectDaysAgo(days)
            await Task.yield()
            await waitUntil(timeout: 20, actions.isDayLoaded)
            let loaded = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            try? await Task.sleep(for: .seconds(4))
            emit(name, ["days_ago": Double(days), "loaded_ms": loaded, "main_cpu_4s_ms": mainCPUMs() - main, "rows": Double(actions.dayRowCount())])
        }
        // 시간 끌기: 손가락으로 끌 때처럼 「끄는 중」을 켜고 화면 틱(16ms)마다 고른 분을 옮긴다(3초에 하루 왕복).
        // 사이드바의 손짓 판정만 거치지 않는다.
        actions.selectDaysAgo(1)
        await waitUntil(timeout: 20, actions.isDayLoaded)
        try? await Task.sleep(for: .seconds(4))
        for _ in 0..<3 {
            MapHomeInteractionMonitor.shared.begin("bench_scrub")
            actions.setScrubbing(true)
            let began = CACurrentMediaTime()
            var last: Int?
            while CACurrentMediaTime() - began < 6 {
                let phase = (CACurrentMediaTime() - began).truncatingRemainder(dividingBy: 3) / 3
                let minute = Int((1 - abs(phase * 2 - 1)) * 1_439)
                if minute != last { actions.setMinute(minute); last = minute }
                try? await Task.sleep(for: .milliseconds(16))
            }
            actions.setScrubbing(false)
            MapHomeInteractionMonitor.shared.end("bench_scrub")
            try? await Task.sleep(for: .seconds(2))
        }
        actions.setMinute(nil)
        if ProcessInfo.processInfo.arguments.contains("-autoBenchMapPan") {
            for _ in 0..<3 {
                MapHomeInteractionMonitor.shared.begin("bench_pan")
                NotificationCenter.default.post(name: MapHomeVectorBenchPan.notification, object: nil)
                try? await Task.sleep(for: .seconds(MapHomeVectorBenchPan.seconds))
                MapHomeInteractionMonitor.shared.end("bench_pan")
                try? await Task.sleep(for: .seconds(3))
            }
        }
        for (name, set) in [("ledger", actions.setLedger), ("travel", actions.setTravel)] {
            for round in 0..<4 {
                MapHomeInteractionMonitor.shared.begin("bench_open_\(name)_\(round == 0 ? "cold" : "warm")", duration: 1.5)
                set(true)
                try? await Task.sleep(for: .seconds(3))
                set(false)
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
        actions.selectDaysAgo(0)
        try? await Task.sleep(for: .seconds(3))
        let memory = footprintMB()
        emit("memory", ["footprint_mb": memory.now, "peak_mb": memory.peak])
        print("PRFBENCH done")
    }

    static func emit(_ name: String, _ values: [String: Double]) {
        let body = values.sorted { $0.key < $1.key }.map { "\($0.key)=\(($0.value * 10).rounded() / 10)" }.joined(separator: " ")
        print("PRFBENCH \(name) \(body)")
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let began = ProcessInfo.processInfo.systemUptime
        while !condition(), ProcessInfo.processInfo.systemUptime - began < timeout {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func mainCPUMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

    private static func processCPUMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000 }

    /// 시작 단계별 시각(PRF1117A01). 프로세스 시작부터 잰 ms만 찍는다.
    nonisolated static func stage(_ name: String) {
        guard ProcessInfo.processInfo.arguments.contains("-autoBenchPerf") else { return }
        print("PRFBENCH stage \(name)=\(Int(sinceProcessStartMs().rounded()))")
    }

    nonisolated static func sinceProcessStartMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        return (Date().timeIntervalSince1970 - Double(start.tv_sec) - Double(start.tv_usec) / 1_000_000) * 1_000
    }

    private static func footprintMB() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (-1, -1) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
#endif
