import AVFoundation
import Foundation
import TaptionPlanCore

// MARK: - Voice memo and notifications

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

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
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
