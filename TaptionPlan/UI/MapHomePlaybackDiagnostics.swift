import CoreLocation
import Foundation
import SwiftUI

/// 재생 틱 간격 계측(PLY1029A01). 재생이 끝날 때 `playback_frame_stats`로 남겨 실제 120Hz인지 기기 로그에서 본다.
struct MapHomePlaybackFrameStats {
    var ticks = 0
    var over12ms = 0
    var over20ms = 0
    var maximumMs = 0.0
    /// 구동기가 한 프레임에 쓴 계산 시간(위치·줌·카메라 놓기). 틱 간격과 견줘 어디서 막히는지 가른다(PLY1029A08).
    var stepTotalMs = 0.0
    var stepMaximumMs = 0.0
    /// 재생 동안 지도 오버레이 본문을 다시 계산한 횟수. 화면 전체가 얼마나 자주 다시 그려지는지 본다.
    @MainActor static var overlayEvaluations = 0
    private var overlayEvaluationsAtStart: Int?
    /// 지도 엔진이 실제로 그린 프레임 수와, 재생 중 SwiftUI 카메라 명령을 막은 횟수(PLY1029A08).
    @MainActor static var mapRenderedFrames = 0
    @MainActor static var blockedCameraCommands = 0
    private var mapRenderedFramesAtStart: Int?
    private var blockedCameraCommandsAtStart: Int?
    var cameraApplies = 0
    var cameraSkips = 0
    /// 틱 간격 분포(ms): 9 미만 / 9~12 / 12~17 / 17~25 / 25~50 / 50 이상. 120Hz면 대부분 첫 칸이어야 한다.
    var buckets = [Int](repeating: 0, count: 6)
    private var startUptime: TimeInterval?

    @MainActor static func noteOverlayEvaluation() -> Bool {
        overlayEvaluations &+= 1
        return true
    }

    mutating func addStep(_ seconds: TimeInterval) {
        stepTotalMs += seconds * 1_000
        stepMaximumMs = max(stepMaximumMs, seconds * 1_000)
    }

    @MainActor mutating func begin() {
        startUptime = ProcessInfo.processInfo.systemUptime
        overlayEvaluationsAtStart = Self.overlayEvaluations
        mapRenderedFramesAtStart = Self.mapRenderedFrames
        blockedCameraCommandsAtStart = Self.blockedCameraCommands
    }

    mutating func add(_ elapsed: TimeInterval) {
        ticks += 1
        let ms = elapsed * 1_000
        buckets[ms < 9 ? 0 : ms < 12 ? 1 : ms < 17 ? 2 : ms < 25 ? 3 : ms < 50 ? 4 : 5] += 1
        if elapsed > MapHomeDayPlaybackMath.droppedFrameInterval { over12ms += 1 }
        if elapsed > 0.020 { over20ms += 1 }
        maximumMs = max(maximumMs, elapsed * 1_000)
    }

    @MainActor func record() {
        guard ticks > 0 else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_frame_stats",
            metrics: ["ticks": Double(ticks), "over_12ms": Double(over12ms),
                      "over_20ms": Double(over20ms), "max_ms": maximumMs.rounded(),
                      // 키에 "step"을 쓰면 로그 정리가 걸음 수로 보고 지운다 — drv로 쓴다.
                      "drv_avg_ms": (stepTotalMs / Double(ticks) * 100).rounded() / 100,
                      "drv_max_ms": (stepMaximumMs * 100).rounded() / 100,
                      "tk_lt9": Double(buckets[0]), "tk_9_12": Double(buckets[1]), "tk_12_17": Double(buckets[2]),
                      "tk_17_25": Double(buckets[3]), "tk_25_50": Double(buckets[4]), "tk_ge50": Double(buckets[5]),
                      "overlay_evals": Double(Self.overlayEvaluations - (overlayEvaluationsAtStart ?? Self.overlayEvaluations)),
                      "map_frames": Double(Self.mapRenderedFrames - (mapRenderedFramesAtStart ?? Self.mapRenderedFrames)),
                      "blocked_camera": Double(Self.blockedCameraCommands - (blockedCameraCommandsAtStart ?? Self.blockedCameraCommands)),
                      "camera_applies": Double(cameraApplies), "camera_skips": Double(cameraSkips),
                      "wall_s": startUptime.map { ((ProcessInfo.processInfo.systemUptime - $0) * 10).rounded() / 10 } ?? -1,
                      // 비용 지표: 앱 메모리 점유(MB)와 기기 열 상태(0 정상~3 심각). 오래된 기기에서 재생 비용을 가린다(ARC1030A04).
                      "mem_mb": MapHomeMemoryFootprint.megabytes().rounded(),
                      "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue)]
        )
    }
}

/// 이 앱이 쓰는 물리 메모리(phys_footprint, MB). 메모리 경고가 나기 전에 재생·지도의 메모리 비용을 본다.
enum MapHomeMemoryFootprint {
    static func megabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// 재생 틱을 화면 주사율(CADisplayLink, 80~120Hz)에 맞춘다(PLY1029A02).
/// `Task.sleep(8.33ms)`는 깨어나는 시각이 화면 갱신과 어긋나 어떤 프레임은 두 번, 어떤 프레임은 한 번도
/// 못 움직여 뚝뚝 끊겼다. 한 프레임에 한 번 깨우고, 지난 프레임부터의 실제 경과 시간을 돌려준다.
@MainActor
final class MapHomePlaybackClock {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<TimeInterval?, Never>?
    private var lastTimestamp: CFTimeInterval = 0

    /// 다음 화면 프레임까지 기다린다. 작업이 취소되면 nil.
    func nextFrame() async -> TimeInterval? {
        if link == nil { start() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (next: CheckedContinuation<TimeInterval?, Never>) in
                continuation?.resume(returning: nil)
                continuation = next
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp == 0 ? link.duration : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let pending = continuation
        continuation = nil
        pending?.resume(returning: max(0, elapsed))
    }
}

/// 재생 중 지도 화면의 무거운 getter가 쓴 시간을 함수별로 모은다(ARC1030A01). 재생이 끝날 때 `playback_probe`로 남긴다.
/// Instruments가 기기에 붙지 못하는 밤에도 같은 자동 측정으로 병목을 읽으려고 넣었다.
@MainActor
enum MapHomePlaybackProbe {
    private(set) static var isActive = false
    private static var totals: [String: (ms: Double, calls: Int, maxMs: Double)] = [:]
    /// `MapHomeView.body`를 평가하는 동안에만 true. 이때 분 값을 읽는 곳을 호출 위치로 센다(어디가 본문을 분에 묶는지 가린다).
    static var inBody = false
    private static var minuteReaders: [String: Int] = [:]

    private static var readCounter = 0

    static func noteMinuteRead() {
        guard isActive, inBody else { return }
        // 호출 위치를 매번 적으면 추적 자체가 재생을 망친다(callStackSymbols가 한 번에 ~10ms). 25번에 한 번만 센다.
        readCounter &+= 1
        guard readCounter.isMultiple(of: 25) else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(4).map { frame -> String in
            let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? String(parts[3]).prefix(80).description : frame
        }
        minuteReaders[frames.joined(separator: " < "), default: 0] += 1
    }

    struct Token {
        let name: String
        let start: TimeInterval
    }

    static func begin(_ name: String) -> Token {
        Token(name: name, start: isActive ? ProcessInfo.processInfo.systemUptime : 0)
    }

    static func end(_ token: Token) {
        guard isActive else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - token.start) * 1_000
        var entry = totals[token.name] ?? (0, 0, 0)
        entry.ms += ms
        entry.calls += 1
        entry.maxMs = max(entry.maxMs, ms)
        totals[token.name] = entry
    }

    static func start() {
        totals = [:]
        isActive = true
    }

    /// 측정 시험이 로그를 거치지 않고 읽는 누적값(ARC1103A01).
    static func currentTotals() -> [String: (ms: Double, calls: Int, maxMs: Double)] { totals }

    static func stop() {
        isActive = false
        totals = [:]
    }

    static func stopAndRecord() {
        guard isActive else { return }
        isActive = false
        var metrics: [String: Double] = [:]
        for (name, entry) in totals {
            metrics["\(name)_ms"] = (entry.ms * 10).rounded() / 10
            metrics["\(name)_n"] = Double(entry.calls)
            metrics["\(name)_max"] = (entry.maxMs * 10).rounded() / 10
        }
        totals = [:]
        TaptionPlanDiagnosticsLogger.shared.record("playback_probe", metrics: metrics)
        // 본문이 분을 읽은 위치(상위 12개). 로그 기록은 한 줄에 몰아 둔다.
        let readers = minuteReaders.sorted { $0.value > $1.value }.prefix(12)
        minuteReaders = [:]
        if !readers.isEmpty {
            TaptionPlanDiagnosticsLogger.shared.record(
                "playback_reader_trace",
                fields: Dictionary(uniqueKeysWithValues: readers.enumerated().map { ("r\($0.offset)", "\($0.element.value)× \($0.element.key)") })
            )
        }
    }
}
