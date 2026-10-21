import AVFoundation
import Photos
import ReplayKit
import Speech
import SwiftUI
import UIKit

/// 메모 입력용 음성 받아쓰기(STT). 인식된 글자만 돌려주고 소리는 저장하지 않는다.
@MainActor
@Observable
final class MapHomeDictation {
    var isListening = false
    var transcript = ""
    var errorMessage: String?

    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(localeIdentifier: String) async {
        guard !isListening else { return }
        errorMessage = nil
        transcript = ""
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            errorMessage = "음성 인식 권한이 필요합니다. 설정에서 허용해 주세요."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "마이크 권한이 필요합니다. 설정에서 허용해 주세요."
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "지금은 음성 인식을 쓸 수 없습니다."
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed { self.stop() }
                }
            }
            isListening = true
        } catch {
            errorMessage = "마이크를 시작하지 못했습니다."
            stop()
        }
    }

    func stop() {
        // 시작하지 않았으면 마이크 장치·오디오 세션을 건드리지 않는다(편집 화면을 닫을 때마다 불린다).
        guard isListening || request != nil || task != nil else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

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
    /// 연봉 카운터(재생 시각까지 번 돈).
    var salary = true

    static let storageKey = "mapHomeRecordingLayers"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeSidebar = try c.decodeIfPresent(Bool.self, forKey: .timeSidebar) ?? timeSidebar
        weatherSidebar = try c.decodeIfPresent(Bool.self, forKey: .weatherSidebar) ?? weatherSidebar
        sidebarMemos = try c.decodeIfPresent(Bool.self, forKey: .sidebarMemos) ?? sidebarMemos
        mapMemos = try c.decodeIfPresent(Bool.self, forKey: .mapMemos) ?? mapMemos
        routes = try c.decodeIfPresent(Bool.self, forKey: .routes) ?? routes
        footprints = try c.decodeIfPresent(Bool.self, forKey: .footprints) ?? footprints
        photos = try c.decodeIfPresent(Bool.self, forKey: .photos) ?? photos
        cat = try c.decodeIfPresent(Bool.self, forKey: .cat) ?? cat
        salary = try c.decodeIfPresent(Bool.self, forKey: .salary) ?? salary
    }

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
    /// 시작하지 못했을 때 사용자에게 보여줄 이유.
    private(set) var lastFailureMessage: String?

    var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    func start() async -> Bool {
        let recorder = RPScreenRecorder.shared()
        lastFailureMessage = nil
        guard recorder.isAvailable else {
            lastFailureMessage = "이 기기·상태에서는 화면 녹화를 사용할 수 없습니다(다른 앱이 화면을 녹화·미러링 중인지 확인해 주세요)."
            return false
        }
        guard !recorder.isRecording else {
            lastFailureMessage = "이미 화면 녹화 중입니다. 제어 센터에서 녹화를 끄고 다시 시도해 주세요."
            return false
        }
        recorder.isMicrophoneEnabled = false
        do {
            try await recorder.startRecording()
            isRecording = true
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_started")
            return true
        } catch {
            lastFailureMessage = "화면 녹화를 시작하지 못했습니다: \(error.localizedDescription)"
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_recording_start_failed",
                level: .error,
                fields: ["error": error.localizedDescription]
            )
            return false
        }
    }

    /// 화면 기록 허용 알림은 녹화를 시작할 때만 뜨므로, 잠깐 시작했다 바로 멈추고 파일은 버린다. 허용되면 true.
    func probePermission() async -> Bool {
        guard await start() else { return false }
        if let url = await stop() { try? FileManager.default.removeItem(at: url) }
        return true
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOKKI-Plan-\(Int(Date.now.timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        do {
            try await RPScreenRecorder.shared().stopRecording(withOutput: url)
            isRecording = false
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_stopped", metrics: ["bytes": Double(bytes)])
            return url
        } catch {
            isRecording = RPScreenRecorder.shared().isRecording
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
    static func photoAddStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

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
    @State private var photoStatus = MapHomeScreenRecordingStore.photoAddStatus()

    private var photoAllowed: Bool { photoStatus == .authorized || photoStatus == .limited }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("재생 화면 녹화", "Record playback"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            Text(language.text("지도는 항상 보입니다. 영상에 넣을 항목을 고르세요.", "The map is always shown. Choose what to include."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            permissionRow
            toggle(language.text("시간 사이드바", "Time sidebar"), $layers.timeSidebar)
            toggle(language.text("날씨 사이드바", "Weather sidebar"), $layers.weatherSidebar)
            toggle(language.text("사이드바 메모", "Sidebar memos"), $layers.sidebarMemos)
            toggle(language.text("지도 메모", "Map memos"), $layers.mapMemos)
            toggle(language.text("사진 (시간에 맞춰 나타남)", "Photos (appear with time)"), $layers.photos)
            toggle(language.text("경로", "Route"), $layers.routes)
            toggle(language.text("발자국", "Footprints"), $layers.footprints)
            toggle(language.text("화랑이 (끄면 화살표)", "Character (arrow when off)"), $layers.cat)
            toggle(language.text("연봉 카운터", "Salary counter"), $layers.salary)
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
        .task {
            // 화면에 들어올 때 권한이 없으면 바로 묻는다(결정 전일 때만 시스템 창이 뜬다).
            if photoStatus == .notDetermined {
                _ = await MapHomeScreenRecordingStore.requestPhotoAddAccess()
            }
            photoStatus = MapHomeScreenRecordingStore.photoAddStatus()
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: photoAllowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(photoAllowed ? Color.green : Color.orange)
            Text(photoAllowed
                 ? language.text("사진 저장 권한 허용됨 · 화면 녹화 권한은 녹화 시작 때 시스템이 묻습니다", "Photo saving allowed · The system asks for screen recording when it starts")
                 : language.text("사진 저장 권한이 필요합니다", "Photo saving permission is needed"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            Spacer(minLength: 0)
            if !photoAllowed, photoStatus != .notDetermined,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Button(language.text("설정 열기", "Open Settings")) { UIApplication.shared.open(url) }
                    .font(.system(size: 12, weight: .bold))
            }
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .tint(Color.tpAccent)
    }
}
