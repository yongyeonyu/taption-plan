import AVFoundation
import UIKit
import XCTest
@testable import TaptionPlan

/// PLR1104A01: 합성 여행(서울→방콕 3박 4일)을 실제로 렌더해 시간·메모리·타일 초과·크기를 잰다.
/// 지도 타일을 받으므로 `TEST_RUNNER_TAPTION_RANGE_RENDER_SECONDS`를 줄 때만 돈다. 사진 앱에는 저장하지 않는다.
@MainActor
final class MapHomeRangeRenderBenchTests: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func tripSamples(start: Date) -> [MapHomeRangeTripPlan.Sample] {
        let origin = start.timeIntervalSinceReferenceDate
        func sample(_ minute: Double, _ latitude: Double, _ longitude: Double) -> MapHomeRangeTripPlan.Sample {
            .init(time: origin + minute * 60, latitude: latitude, longitude: longitude)
        }
        var samples = stride(from: 0.0, through: 120, by: 5).map { sample($0, 37.46, 126.44) }
        // 비행 뒤 방콕에서 나흘 동안 낮에 돌아다니고 숙소에서 잔다.
        let hotel = (latitude: 13.745, longitude: 100.535)
        let spots = [(13.7500, 100.4913), (13.7466, 100.5340), (13.7246, 100.4930), (13.7649, 100.5383), (13.6900, 100.7501)]
        var minute = 500.0
        for (day, spot) in spots.enumerated() {
            samples += stride(from: minute, through: minute + 300, by: 5).map { sample($0, hotel.latitude, hotel.longitude) }
            minute += 305
            for step in 1...40 {
                let ratio = Double(step) / 40
                samples.append(sample(minute + Double(step),
                                      hotel.latitude + (spot.0 - hotel.latitude) * ratio + sin(ratio * 9) * 0.002,
                                      hotel.longitude + (spot.1 - hotel.longitude) * ratio))
            }
            minute += 45
            samples += stride(from: minute, through: minute + 90, by: 5).map { sample($0, spot.0, spot.1) }
            minute += 95
            if day < spots.count - 1 {
                for step in 1...40 {
                    let ratio = Double(step) / 40
                    samples.append(sample(minute + Double(step),
                                          spot.0 + (hotel.latitude - spot.0) * ratio,
                                          spot.1 + (hotel.longitude - spot.1) * ratio))
                }
                minute += 45
            }
        }
        return samples
    }

    /// 비동기 시험 함수로 돌리면 시험 도구가 주 실행 루프를 지도 엔진이 쓰는 모드로 돌리지 않아 타일이 오지 않는다.
    /// 그래서 동기 함수에서 기대값으로 기다린다.
    func testRenderSyntheticTrip() throws {
        guard ProcessInfo.processInfo.environment["TAPTION_RANGE_RENDER_SECONDS"] != nil else {
            throw XCTSkip("측정 때만 실행")
        }
        let finished = expectation(description: "render")
        var failure: Error?
        Task { @MainActor in
            do { try await render() } catch { failure = error }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 900)
        if let failure { throw failure }
    }

    private func render() async throws {
        let raw = ProcessInfo.processInfo.environment["TAPTION_RANGE_RENDER_SECONDS"] ?? ""
        let seconds = try XCTUnwrap(Double(raw))
        let style = try XCTUnwrap(MapDisplayStyle.openFreeMapStyles.first?.runtimeStyle.mapHomeVectorStyle)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(4 * 86_400))
        let plan = try XCTUnwrap(MapHomeRangeTripPlan.make(samples: tripSamples(start: start), span: span, durationSeconds: seconds))
        let renderer = MapHomePlaybackVideoRenderer(
            style: style,
            frames: { plan.frames(fps: $0) },
            overlay: MapHomeRangeVideoOverlay(plan: plan, language: .korean, accessoryID: nil)
        )
        // BGM1104A02: 값을 주면 그 곡을 넣어 렌더한다.
        renderer.music = ProcessInfo.processInfo.environment["TAPTION_RANGE_RENDER_MUSIC"]
            .flatMap(MapHomePlaybackMusicTrack.init(rawValue:))?.url
        var peak = footprintMB()
        let before = peak
        let started = Date()
        let url: URL
        do {
            var progress = 0.0, reportedStep = -1
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    print("PLR_BENCH watch after=\(Date().timeIntervalSince(started)) progress=\(progress) app=\(UIApplication.shared.applicationState.rawValue) timeouts=\(renderer.timeoutCount)")
                }
            }
            defer { watchdog.cancel() }
            url = try await renderer.render { value in
                progress = value
                peak = max(peak, self.footprintMB())
                let step = Int(value * 20)
                if step != reportedStep {
                    reportedStep = step
                    print("PLR_BENCH progress=\(value) after=\(Date().timeIntervalSince(started)) timeouts=\(renderer.timeoutCount) peak_mb=\(peak)")
                }
            }
        } catch {
            print("PLR_BENCH failed type=\(type(of: error)) after=\(Date().timeIntervalSince(started)) error=\(String(reflecting: error))")
            throw error
        }
        let elapsed = Date().timeIntervalSince(started)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let frames = Int(seconds * 60)
        print("PLR_BENCH frames=\(frames) seconds=\(elapsed) avg_ms=\(elapsed * 1_000 / Double(frames)) timeouts=\(renderer.timeoutCount) mb=\(bytes / 1_048_576) before_mb=\(before) peak_mb=\(peak) items=\(plan.items.count) route=\(plan.route.count) km=\(plan.totalMeters / 1_000)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PLR1104A01", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("trip.mov")
        try FileManager.default.moveItem(at: url, to: kept)
        print("PLR_BENCH movie=\(kept.path)")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: kept))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for ratio in [0.05, 0.3, 0.6, 0.85, 0.999] {
            let time = CMTime(seconds: seconds * ratio, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            let data = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.8))
            try data.write(to: folder.appendingPathComponent("frame-\(Int(ratio * 1_000)).jpg"))
        }
    }
}
