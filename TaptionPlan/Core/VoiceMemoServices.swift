import AVFoundation
import Foundation
import TaptionPlanCore

// MARK: - Voice memo and notifications

/// 음성 메모 파일은 시스템이 지우지 않는 앱 지원 폴더(`TaptionPlan/VoiceMemos`)에 둔다.
/// 기록에는 절대 경로가 남으므로, 임시 폴더 녹음이나 앱 컨테이너가 바뀐 옛 경로는 파일 이름으로 다시 찾는다.
enum VoiceMemoStorage {
    static func liveDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TaptionPlan/VoiceMemos", isDirectory: true)
    }

    /// 앱 폴더에 같은 이름이 있으면 그 경로, 저장된 경로나 임시 폴더에 있으면 앱 폴더로 옮긴 경로를 돌려준다.
    /// 어디에도 없으면(지워졌거나 다른 기기의 녹음) 저장된 경로를 그대로 둔다.
    static func kept(
        _ path: String, directory: URL,
        temporary: URL = FileManager.default.temporaryDirectory, fileManager: FileManager = .default
    ) -> String {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return path }
        let target = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: target.path) { return target.path }
        for source in [URL(fileURLWithPath: path), temporary.appendingPathComponent(name)]
        where fileManager.fileExists(atPath: source.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
                return target.path
            } catch {
                return source.path
            }
        }
        return path
    }
}

@MainActor
final class VoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeURL: URL?

    func requestPermission() async -> Bool {
        await Self.requestRecordPermission()
    }

    /// 시스템 콜백은 백그라운드 큐에서 온다. 메인 액터 격리를 피하려고 nonisolated로 받는다.
    nonisolated private static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(in directory: URL) throws -> URL {
        _ = stop()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "memo-\(UUID().uuidString).m4a"
        )
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(
                true,
                options: .notifyOthersOnDeactivation
            )
            guard session.isInputAvailable,
                  !session.currentRoute.inputs.isEmpty else {
                throw VoiceMemoRecordingError.inputUnavailable
            }

            let sampleRate = session.sampleRate
            let channelCount = session.inputNumberOfChannels
            guard sampleRate > 0, channelCount > 0 else {
                throw VoiceMemoRecordingError.invalidInputFormat
            }

            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: Int(channelCount),
                    AVEncoderBitRateKey: 128_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
            )
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                throw VoiceMemoRecordingError.couldNotStart
            }
            self.recorder = recorder
            activeURL = url
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            throw error
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        defer { activeURL = nil }
        return activeURL
    }
}

enum VoiceMemoRecordingError: LocalizedError {
    case inputUnavailable
    case invalidInputFormat
    case couldNotStart

    var errorDescription: String? {
        message()
    }

    func message(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case .inputUnavailable:
            AppLanguagePreference.text(
                korean: "마이크 입력 장치를 사용할 수 없습니다.",
                english: "The microphone input device is unavailable.",
                preference: preference
            )
        case .invalidInputFormat:
            AppLanguagePreference.text(
                korean: "현재 오디오 입력 형식을 확인할 수 없습니다.",
                english: "The current audio input format could not be determined.",
                preference: preference
            )
        case .couldNotStart:
            AppLanguagePreference.text(
                korean: "녹음 준비를 완료하지 못했습니다.",
                english: "Recording could not be prepared.",
                preference: preference
            )
        }
    }
}

@MainActor
final class VoiceMemoPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    func play(filePath: String) throws {
        stop()
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceMemoPlaybackError.fileMissing
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw VoiceMemoPlaybackError.couldNotStart
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 대리자는 메인 액터 밖에서 불릴 수 있어(옛 Xcode는 준수를 막음) 같은 플레이어일 때만 메인에서 마무리한다.
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(of: finished)
        }
    }

    private func finishPlayback(of finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished else { return }
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        onFinish?()
    }
}

enum VoiceMemoPlaybackError: LocalizedError {
    case fileMissing
    case couldNotStart

    var errorDescription: String? {
        message()
    }

    func message(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case .fileMissing:
            AppLanguagePreference.text(
                korean: "음성 메모 파일을 찾지 못했습니다.",
                english: "The voice memo file could not be found.",
                preference: preference
            )
        case .couldNotStart:
            AppLanguagePreference.text(
                korean: "음성 메모 재생을 시작하지 못했습니다.",
                english: "Voice memo playback could not be started.",
                preference: preference
            )
        }
    }
}
