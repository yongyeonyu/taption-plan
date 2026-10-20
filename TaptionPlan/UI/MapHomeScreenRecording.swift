import Photos
import ReplayKit
import SwiftUI
import UIKit

/// 녹화 영상에 넣을 표시 레이어. 지도는 항상 보인다.
struct MapHomeRecordingLayers: Codable, Equatable {
    var timeSidebar = true
    var weatherSidebar = true
    var sidebarMemos = true
    var mapMemos = false
    var routes = true
    var footprints = true
    /// 재생 시각에 맞춰 사진이 차례로 나타난다.
    var photos = false
    /// 꺼 두면 화랑이 대신 화살표만 보인다.
    var cat = false

    static let storageKey = "mapHomeRecordingLayers"

    init() {}

    init(rawValue: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(rawValue.utf8))) ?? Self()
    }

    var rawValue: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }
}

/// 앱 화면을 ReplayKit으로 녹화해 임시 mp4 파일로 만든다.
@MainActor
final class MapHomeScreenRecorder {
    private(set) var isRecording = false

    var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    func start() async -> Bool {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable, !recorder.isRecording else { return false }
        recorder.isMicrophoneEnabled = false
        do {
            try await recorder.startRecording()
            isRecording = true
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_started")
            return true
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_recording_start_failed",
                level: .error,
                fields: ["error": error.localizedDescription]
            )
            return false
        }
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOKKI-Plan-\(Int(Date.now.timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        do {
            try await RPScreenRecorder.shared().stopRecording(withOutput: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_stopped", metrics: ["bytes": Double(bytes)])
            return url
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_recording_stop_failed",
                level: .error,
                fields: ["error": error.localizedDescription]
            )
            return nil
        }
    }
}

/// 사진 앱 권한·저장. PhotoKit 완료 핸들러는 백그라운드 큐에서 불리므로 메인 액터와 분리한다.
enum MapHomeScreenRecordingStore {
    static func requestPhotoAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    static func saveToPhotos(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }
}

struct MapHomeShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct MapHomeRecordingOptionsSheet: View {
    @Binding var layers: MapHomeRecordingLayers
    let language: MapHomeLanguage
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("재생 화면 녹화", "Record playback"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            Text(language.text("지도는 항상 보입니다. 영상에 넣을 항목을 고르세요.", "The map is always shown. Choose what to include."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            toggle(language.text("시간 사이드바", "Time sidebar"), $layers.timeSidebar)
            toggle(language.text("날씨 사이드바", "Weather sidebar"), $layers.weatherSidebar)
            toggle(language.text("사이드바 메모", "Sidebar memos"), $layers.sidebarMemos)
            toggle(language.text("지도 메모", "Map memos"), $layers.mapMemos)
            toggle(language.text("사진 (시간에 맞춰 나타남)", "Photos (appear with time)"), $layers.photos)
            toggle(language.text("경로", "Route"), $layers.routes)
            toggle(language.text("발자국", "Footprints"), $layers.footprints)
            toggle(language.text("화랑이 (끄면 화살표)", "Character (arrow when off)"), $layers.cat)
            Button(action: onStart) {
                Label(language.text("녹화하며 재생", "Record and play"), systemImage: "record.circle")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(Color.tpAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpBackground)
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .tint(Color.tpAccent)
    }
}
