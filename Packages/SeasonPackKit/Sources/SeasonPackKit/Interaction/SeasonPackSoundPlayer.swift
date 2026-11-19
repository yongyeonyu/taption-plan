import AVFoundation
import Foundation

/// 소리 한 번에 하나. 재생 중 다른 요청은 무시한다.
@MainActor
public protocol SeasonPackSoundPlaying: AnyObject {
    var isPlaying: Bool { get }
    /// 재생을 시작했으면 true, 이미 재생 중이거나 읽지 못하면 false.
    func play(url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

/// `AVAudioPlayer` 하나(`VoiceMemoPlayer` 모양). 세션은 ambient + mixWithOthers라 듣던 음악을 끊지 않고 무음 스위치를 따른다.
@MainActor
public final class SeasonPackSoundPlayer: NSObject, SeasonPackSoundPlaying, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finish: (@MainActor () -> Void)?

    public var isPlaying: Bool { player?.isPlaying ?? false }

    public func play(url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard !isPlaying else { return false }
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return false }
        next.delegate = self
        guard next.prepareToPlay(), next.play() else { return false }
        player = next
        finish = onFinish
        return true
    }

    public func stop() {
        player?.stop()
        player = nil
        finish = nil
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let callback = finish
        self.player = nil
        finish = nil
        callback?()
    }
}
