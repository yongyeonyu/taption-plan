import AVFoundation
import Photos
import ReplayKit
import Speech
import SwiftUI
import UIKit

/// 메모 입력용 음성 받아쓰기. 말하는 동안 실시간 글자를 보여 주고, 같은 소리를 메모 첨부 파일로도 남긴다.
@MainActor
@Observable
final class MapHomeDictation {
    /// 녹음 중인지.
    var isListening = false
    /// 녹음 끝난 뒤 마지막 글자를 기다리는 중인지.
    var isTranscribing = false
    var transcript = ""
    var errorMessage: String?
    /// 녹음 중 입력 크기(0~1). 웨이브폼 막대에 쓴다.
    private(set) var level: Double = 0
    /// 마지막으로 녹음한 파일(첨부용).
    private(set) var recordedURL: URL?
    /// 말하는 동안 중간 글자가 바뀔 때마다 넘겨준다.
    var onPartial: ((String) -> Void)?
    /// 확정된 글자를 넘겨준다.
    var onTranscribed: ((String) -> Void)?
    /// 녹음이 끝나면 파일 위치를 넘겨준다(메모 첨부용).
    var onRecorded: ((URL) -> Void)?

    private var engine: AVAudioEngine?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var file: AVAudioFile?

    /// 음성 스레드에서 도는 결과 블록은 메인 액터 밖에서 만든다(메인 액터로 만들면 충돌한다).
    private nonisolated static func resultBlock(
        _ deliver: @escaping @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }

    /// 음성 인식이나 마이크 권한이 거부된 상태(설정에서만 바꿀 수 있다).
    static var isPermissionDenied: Bool {
        SFSpeechRecognizer.authorizationStatus() == .denied
            || SFSpeechRecognizer.authorizationStatus() == .restricted
            || AVAudioApplication.shared.recordPermission == .denied
    }

    /// 권한 콜백은 시스템 백그라운드 큐에서 온다. 메인 액터 클로저로 두면 격리 검사에서 SIGTRAP으로 죽으므로 nonisolated로 받는다.
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 마이크 입력을 받아 실시간 인식과 파일 저장을 함께 한다. 음성 스레드에서 돈다.
    private nonisolated static func tapBlock(
        request: SFSpeechAudioBufferRecognitionRequest,
        file: AVAudioFile,
        level: @escaping @Sendable (Double) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            try? file.write(from: buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += data[index] * data[index] }
            let db = 10 * log10(max(sum / Float(count), 1e-10))
            level(Double(min(max((db + 50) / 50, 0), 1)))
        }
    }

    /// 녹음을 시작한다. 말하는 동안 중간 글자를 onPartial로 보낸다.
    func start(localeIdentifier: String) async {
        guard !isListening, !isTranscribing else { return }
        TaptionPlanDiagnosticsLogger.shared.record("voice_memo_start_requested")
        errorMessage = nil
        transcript = ""
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = "음성 인식 권한이 필요합니다. 설정에서 허용해 주세요."
            return
        }
        guard await Self.requestMicrophonePermission() else {
            errorMessage = "마이크 권한이 필요합니다. 설정에서 허용해 주세요."
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "지금은 음성 인식을 쓸 수 없습니다."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("memo-voice-\(UUID().uuidString).m4a")
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.tapBlock(
                request: request,
                file: file,
                level: { [weak self] value in
                    Task { @MainActor [weak self] in self?.level = value }
                }
            ))
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.file = file
            self.liveRequest = request
            recordedURL = url
            isListening = true
            liveTask = recognizer.recognitionTask(with: request, resultHandler: Self.resultBlock { [weak self] text, finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text, !text.isEmpty, !finished { self.onPartial?(text) }
                    guard finished else { return }
                    self.isTranscribing = false
                    self.transcript = text ?? ""
                    if let text, !text.isEmpty { self.onTranscribed?(text) }
                }
            })
            TaptionPlanDiagnosticsLogger.shared.record("voice_memo_recording_started")
        } catch {
            errorMessage = "마이크를 시작하지 못했습니다."
            // 시작에 실패하면 탭과 엔진을 바로 정리한다(stop은 녹음 중일 때만 동작).
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            file = nil
            liveRequest = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 녹음을 끝낸다. 마지막 글자는 인식이 확정되면 onTranscribed로 간다.
    func stop() {
        guard isListening else { return }
        TaptionPlanDiagnosticsLogger.shared.record("voice_memo_recording_stopped")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        liveRequest?.endAudio()
        isListening = false
        isTranscribing = liveTask != nil
        level = 0
        engine = nil
        file = nil
        liveRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = recordedURL { onRecorded?(url) }
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
        // 앱이 남긴 녹화가 아직 돌고 있으면(이전 시도가 멈추지 못한 경우) 먼저 정리하고 새로 시작한다.
        if recorder.isRecording, !isRecording {
            let leftover = FileManager.default.temporaryDirectory.appendingPathComponent("BOKKI-Plan-leftover.mp4")
            try? FileManager.default.removeItem(at: leftover)
            try? await recorder.stopRecording(withOutput: leftover)
            try? FileManager.default.removeItem(at: leftover)
        }
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
        // 이미 녹화 중이면 권한은 있는 것이다. 다시 시작하지 않는다.
        if isRecording || RPScreenRecorder.shared().isRecording { return true }
        guard await start() else { return false }
        if let url = await stop() {
            try? FileManager.default.removeItem(at: url)
        } else {
            // 멈추지 못했으면 상태를 실제 녹화 상태에 맞춘다(다음 녹화가 막히지 않게).
            isRecording = RPScreenRecorder.shared().isRecording
        }
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

/// 메모 입력 칸(UITextView). 녹음 중에는 소프트 키보드 대신 높이 0짜리 입력뷰를 써서 커서만 남긴다.
struct MapHomeMemoTextView: UIViewRepresentable {
    @Binding var text: String
    var suppressesKeyboard: Bool
    /// 값이 바뀌면 입력칸에 포커스를 준다(녹음 버튼을 누르면 자동으로 커서가 간다).
    var focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 17)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(120, height))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            // 글자를 넣은 뒤 크기를 다시 재고 그려야 포커스 전까지 안 보이던 문제가 없다.
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        if context.coordinator.suppresses != suppressesKeyboard {
            context.coordinator.suppresses = suppressesKeyboard
            view.inputView = suppressesKeyboard ? UIView(frame: .zero) : nil
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            view.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MapHomeMemoTextView
        var suppresses = false
        var focusToken = 0

        init(parent: MapHomeMemoTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
        }
    }
}
