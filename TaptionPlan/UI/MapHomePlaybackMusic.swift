import AVFoundation
import Observation
import os

/// 재생 영상의 배경 음악(BGM1104A02). 코드로 합성한 곡만 앱 target에 넣는다.
enum MapHomePlaybackMusicTrack: String, CaseIterable, Identifiable, Sendable {
    case sunnyStroll = "01-sunny-stroll"
    case tiptoeAlley = "02-tiptoe-alley"
    case riverbankBreeze = "03-riverbank-breeze"
    case neighborhoodLoop = "05-neighborhood-loop"
    case sunsetHome = "06-sunset-home"
    case pixelPicnic = "07-pixel-picnic"
    case starlightMap = "09-starlight-map"
    case cloudBicycle = "10-cloud-bicycle"
    case travelBag = "11-travel-bag"
    case catParade = "12-cat-parade"

    /// 저장값에서 "음악 없음"을 뜻한다.
    static let noneID = "none"
    static let defaultID = sunnyStroll.rawValue

    /// 저장값을 읽는다. 없어진 곡이면 첫 곡으로 돌아간다.
    static func stored(_ raw: String) -> Self? {
        raw == noneID ? nil : Self(rawValue: raw) ?? .sunnyStroll
    }

    var id: String { rawValue }
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "m4a") }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .sunnyStroll: language.text("햇살 산책", "Sunny Stroll")
        case .tiptoeAlley: language.text("살금살금 골목", "Tiptoe Alley")
        case .riverbankBreeze: language.text("강변 산들바람", "Riverbank Breeze")
        case .neighborhoodLoop: language.text("동네 한 바퀴", "Neighborhood Loop")
        case .sunsetHome: language.text("노을 지는 귀갓길", "Sunset Home")
        case .pixelPicnic: language.text("픽셀 소풍", "Pixel Picnic")
        case .starlightMap: language.text("별빛 지도", "Starlight Map")
        case .cloudBicycle: language.text("구름 자전거", "Cloud Bicycle")
        case .travelBag: language.text("여행 가방", "Travel Bag")
        case .catParade: language.text("고양이 행진", "Cat Parade")
        }
    }
}

/// 곡을 영상 길이만큼 PCM으로 흘려 보낸다. 반복하고, 이음새를 겹쳐 잇고, 끝을 페이드아웃한다.
/// 파일에서 조금씩 읽으므로 영상이 길어도 곡 전체를 메모리에 올리지 않는다.
final class MapHomePlaybackMusicStream {
    static let fadeSeconds = 1.5
    /// 이음새에서 곡 끝과 곡 처음을 겹치는 길이(약 46ms).
    static let seamFrames: AVAudioFramePosition = 2_048
    private static let chunkFrames: AVAudioFramePosition = 4_096

    let format: AVAudioFormat
    let totalFrames: AVAudioFramePosition
    private(set) var producedFrames: AVAudioFramePosition = 0

    private let file: AVAudioFile
    private let channels: Int
    private let seam: AVAudioFramePosition
    private let fadeFrames: AVAudioFramePosition
    private var head: [Float] = []

    init(url: URL, durationSeconds: Double) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        format = file.processingFormat
        channels = Int(format.channelCount)
        guard file.length > 0 else { throw MapHomePlaybackVideoError.writerFailed("empty music") }
        seam = min(Self.seamFrames, file.length / 4)
        totalFrames = AVAudioFramePosition((durationSeconds * format.sampleRate).rounded())
        // 영상이 아주 짧으면 절반까지만 페이드아웃한다.
        fadeFrames = min(AVAudioFramePosition(Self.fadeSeconds * format.sampleRate), totalFrames / 2)
        head = try read(frames: seam).map(Self.samples) ?? []
        file.framePosition = 0
    }

    /// 끝에서 `fadeFrames` 안쪽일 때 줄어드는 음량. 마지막 표본에서 0이 된다.
    static func fadeGain(frame: AVAudioFramePosition, total: AVAudioFramePosition, fadeFrames: AVAudioFramePosition) -> Float {
        let remaining = total - 1 - frame
        guard fadeFrames > 0, remaining < fadeFrames else { return 1 }
        let ratio = Float(max(0, remaining)) / Float(fadeFrames)
        return ratio * ratio
    }

    /// 다음 묶음. 영상 길이를 다 채웠으면 nil.
    func nextBuffer() throws -> AVAudioPCMBuffer? {
        guard producedFrames < totalFrames else { return nil }
        if file.framePosition >= file.length { file.framePosition = seam }
        let seamStart = file.length - seam
        let boundary = file.framePosition < seamStart ? seamStart : file.length
        let wanted = min(Self.chunkFrames, boundary - file.framePosition, totalFrames - producedFrames)
        let position = file.framePosition
        guard let buffer = try read(frames: wanted), buffer.frameLength > 0 else {
            throw MapHomePlaybackVideoError.writerFailed("music read ended early")
        }
        let samples = Self.pointer(buffer)
        if position >= seamStart { blendHead(samples, frames: Int(buffer.frameLength), offset: position - seamStart) }
        for frame in 0..<Int(buffer.frameLength) {
            let gain = Self.fadeGain(frame: producedFrames + AVAudioFramePosition(frame), total: totalFrames, fadeFrames: fadeFrames)
            guard gain < 1 else { continue }
            for channel in 0..<channels { samples[frame * channels + channel] *= gain }
        }
        producedFrames += AVAudioFramePosition(buffer.frameLength)
        return buffer
    }

    /// 곡 끝을 줄이며 곡 처음을 올린다. 다음 바퀴는 겹친 만큼 뒤에서 시작해 박자가 이어진다.
    private func blendHead(_ samples: UnsafeMutablePointer<Float>, frames: Int, offset: AVAudioFramePosition) {
        for frame in 0..<frames {
            let index = Int(offset) + frame
            let angle = (Double(index) + 0.5) / Double(seam) * .pi / 2
            let out = Float(cos(angle)), incoming = Float(sin(angle))
            for channel in 0..<channels {
                let sample = frame * channels + channel
                samples[sample] = samples[sample] * out + head[index * channels + channel] * incoming
            }
        }
    }

    private func read(frames: AVAudioFramePosition) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        return buffer
    }

    private static func pointer(_ buffer: AVAudioPCMBuffer) -> UnsafeMutablePointer<Float> {
        buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
    }

    private static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        return Array(UnsafeBufferPointer(start: pointer(buffer), count: count))
    }
}

/// 음악 입력을 쓰기 도구에 흘려 넣는다. 영상 프레임은 주 스레드에서 그대로 쓰고,
/// 음악은 전용 큐에서 쓰기 도구가 받을 수 있을 때만 읽는다.
final class MapHomePlaybackMusicFeeder: @unchecked Sendable {
    private enum State { case running, finished, failed(String) }

    // 둘 다 전용 큐의 `feed`에서만 쓴다.
    private let input: AVAssetWriterInput
    private let stream: MapHomePlaybackMusicStream
    private let queue = DispatchQueue(label: "com.taption.plan.playback-music", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State.running)

    init(input: AVAssetWriterInput, stream: MapHomePlaybackMusicStream) {
        self.input = input
        self.stream = stream
    }

    var isRunning: Bool {
        state.withLock { if case .running = $0 { true } else { false } }
    }

    var failure: String? {
        state.withLock { if case .failed(let reason) = $0 { reason } else { nil } }
    }

    func start() {
        input.requestMediaDataWhenReady(on: queue) { [self] in feed() }
    }

    private func feed() {
        while isRunning, input.isReadyForMoreMediaData {
            do {
                guard let buffer = try stream.nextBuffer() else {
                    input.markAsFinished()
                    state.withLock { $0 = .finished }
                    return
                }
                let time = CMTime(
                    value: stream.producedFrames - AVAudioFramePosition(buffer.frameLength),
                    timescale: CMTimeScale(stream.format.sampleRate)
                )
                guard input.append(try Self.sampleBuffer(buffer, at: time)) else {
                    state.withLock { $0 = .failed("music append") }
                    return
                }
            } catch {
                state.withLock { $0 = .failed(String(describing: error)) }
                return
            }
        }
    }

    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: time.timescale),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard created == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(
                  sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                  flags: 0, bufferList: buffer.audioBufferList
              ) == noErr
        else { throw MapHomePlaybackVideoError.writerFailed("music sample buffer") }
        return sample
    }
}

/// 곡 미리듣기. 무음 스위치를 따르고 다른 앱 소리에 섞이는 `.ambient`를 쓰며, 끝나면 이전 분류로 돌려 둔다.
@MainActor
@Observable
final class MapHomePlaybackMusicPreview: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: MapHomePlaybackMusicTrack?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var previousCategory: AVAudioSession.Category?

    func play(_ track: MapHomePlaybackMusicTrack) {
        stop()
        guard let url = track.url else { return }
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        do {
            try session.setCategory(.ambient)
            previousCategory = category
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else {
                stop()
                return
            }
            self.player = player
            playing = track
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if playing != nil { playing = nil }
        guard let previousCategory else { return }
        self.previousCategory = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try? session.setCategory(previousCategory)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }
}
