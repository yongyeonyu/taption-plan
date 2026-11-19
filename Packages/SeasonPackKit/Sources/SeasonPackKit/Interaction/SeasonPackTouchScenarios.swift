import Foundation

/// 가사 큐: `atMs` 오름차순, 다음 큐가 오면 바뀌고, 마지막 큐 뒤 2초에 사라진다.
public struct SeasonPackLyricTimeline: Sendable, Equatable {
    public static let tailMs = 2000
    public let cues: [SeasonPackManifest.LyricTrack.Cue]

    public init(cues: [SeasonPackManifest.LyricTrack.Cue]) { self.cues = cues.sorted { $0.atMs < $1.atMs } }

    public func cue(atMs elapsed: Int) -> SeasonPackManifest.LyricTrack.Cue? {
        guard let last = cues.last, elapsed >= (cues.first?.atMs ?? 0), elapsed <= last.atMs + Self.tailMs else { return nil }
        return cues.last { $0.atMs <= elapsed }
    }

    public var totalMs: Int { (cues.last?.atMs ?? 0) + Self.tailMs }
}

public enum SeasonPackEffect: Sendable, Equatable {
    case blink(seconds: Double)
    case playAudio(String)
    /// `restart`가 true면 재생 중에 다시 눌러 가사를 처음부터 다시 시작한다.
    case lyrics(audio: String, restart: Bool)
}

/// 매니페스트 `interactions[]`를 터치에 맞춰 푼다. 앱은 어떤 장면인지 모른다.
/// 정책: 소리가 재생 중이면 다시 눌러도 소리는 끝까지 두고(새로 시작하지 않음), 점멸·가사만 다시 시작한다.
public struct SeasonPackScenarioEngine: Sendable {
    public let interactions: [SeasonPackManifest.Interaction]
    public let characterID: String

    public init(interactions: [SeasonPackManifest.Interaction], characterID: String) {
        self.interactions = interactions; self.characterID = characterID
    }

    public func tap(target: String, audioPlaying: Bool) -> [SeasonPackEffect] {
        interactions.filter { $0.on == "tap" && $0.target == target && matches($0.when) }.flatMap { interaction in
            interaction.actions.compactMap { action -> SeasonPackEffect? in
                switch action.kind {
                case "blink": return .blink(seconds: min(max(action.seconds ?? 6, 0.5), 30))
                case "playAudio": return audioPlaying ? nil : action.audio.map(SeasonPackEffect.playAudio)
                case "lyrics": return action.audio.map { .lyrics(audio: $0, restart: audioPlaying) }
                default: return nil // 모르는 동작은 그 동작만 건너뛴다.
                }
            }
        }
    }

    private func matches(_ condition: SeasonPackManifest.Condition?) -> Bool {
        condition?.characterID.map { $0 == characterID } ?? true
    }
}

public extension SeasonPackManifest {
    /// 이 팩의 소리 한 곡의 파일(자산이 없으면 nil — 가사 말풍선도 띄우지 않는다).
    func audioAssetID(_ audioID: String) -> String? { audio?.first { $0.id == audioID }?.asset }
    func lyricCues(audio audioID: String) -> [LyricTrack.Cue] { lyrics?.first { $0.audio == audioID }?.cues ?? [] }
}
