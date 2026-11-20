import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// 트리 터치·산타 비행·선물·가사 말풍선을 진행시키는 무대. 센터가 하나 들고 있고, 화면은 이 값을 읽어 그리기만 한다.
@MainActor
@Observable
public final class SeasonPackStage {
    public struct Flight: Equatable {
        public var actor: SeasonPackManifest.Actor
        public var startedAt: Date
        /// 산타를 눌러 멈춘 진행도(비행 중이면 nil).
        public var frozenProgress: Double?
        public var ref: SeasonPackRef
    }

    public struct Burst: Equatable {
        public var origin: CGPoint
        public var startedAt: Date
        public var images: [String]
        public var gifts: [SeasonPackActorMath.Gift]
    }

    public private(set) var fastBlinkUntil: Date?
    public private(set) var lyricText: String?
    public private(set) var flight: Flight?
    public private(set) var burst: Burst?

    @ObservationIgnored private weak var center: SeasonPackCenter?
    @ObservationIgnored var sound: any SeasonPackSoundPlaying = SeasonPackSoundPlayer()
    @ObservationIgnored private var flightLoop: Task<Void, Never>?
    @ObservationIgnored private var lyricTask: Task<Void, Never>?
    @ObservationIgnored private var blinkTask: Task<Void, Never>?
    @ObservationIgnored private var lastFlights: [String: Date] = [:]
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var round: Task<Void, Never>?

    public init() {}

    func attach(center: SeasonPackCenter) { self.center = center }

    /// 시험용: 소리 재생기를 대역으로 바꾼다.
    public func useSound(_ player: any SeasonPackSoundPlaying) { sound = player }

    public var isAudioPlaying: Bool { sound.isPlaying }

    private var now: Date { center?.host?.now() ?? Date() }

    // MARK: 트리 터치

    /// 집(트리) 터치: 시나리오 효과를 순서대로 — 빠른 점멸 → 캐럴 → 가사. 재생 중이면 점멸·가사만 다시 시작하고 소리는 끝까지 둔다.
    public func houseTapped() {
        guard let center, let pack = center.active, let host = center.host else { return }
        let engine = SeasonPackScenarioEngine(interactions: pack.manifest.interactions ?? [], characterID: host.characterID)
        for effect in engine.tap(target: "house", audioPlaying: sound.isPlaying) {
            switch effect {
            case .blink(let seconds): blink(seconds: seconds)
            case .playAudio(let audioID):
                guard let assetID = pack.manifest.audioAssetID(audioID), let url = pack.assetURL(assetID) else { continue }
                _ = sound.play(url: url) { [weak self] in self?.audioFinished() }
            case .lyrics(let audioID, _):
                guard pack.manifest.audioAssetID(audioID).flatMap({ pack.assetURL($0) }) != nil else { continue }
                startLyrics(SeasonPackLyricTimeline(cues: pack.manifest.lyricCues(audio: audioID)), language: host.languageCode)
            }
        }
    }

    private func blink(seconds: Double) {
        fastBlinkUntil = now.addingTimeInterval(seconds)
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.fastBlinkUntil = nil }
        }
    }

    private func audioFinished() {
        fastBlinkUntil = nil
        blinkTask?.cancel()
    }

    private func startLyrics(_ timeline: SeasonPackLyricTimeline, language: String) {
        lyricTask?.cancel()
        guard !timeline.cues.isEmpty else { return }
        let started = ContinuousClock.now
        lyricTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
                if elapsed > timeline.totalMs { break }
                self?.lyricText = timeline.cue(atMs: elapsed)?.text.resolve(language: language)
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled { self?.lyricText = nil }
        }
    }

    // MARK: 산타

    private var isReduced: Bool { center?.motion.isReduced ?? false }

    func activePackChanged() {
        stopAll()
        startFlightLoop()
    }

    func motionChanged() {
        if isReduced { stopAll() } else { startFlightLoop() }
    }

    /// 다음 비행까지 기다렸다가 날린다. 팩을 처음 받은 직후는 바로 1회, 이후는 3~5분 간격. 줄이기·저전력에서는 돌지 않는다.
    private func startFlightLoop() {
        flightLoop?.cancel()
        guard let center, let pack = center.active, !isReduced, let actors = pack.manifest.actors, !actors.isEmpty else { return }
        let ref = SeasonPackRef(id: pack.id, version: pack.version)
        let throttle = SeasonPackDemoThrottle(defaults: center.defaults)
        flightLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let host = center.host else { return }
                let usable = actors.filter { $0.when?.characterID.map { $0 == host.characterID } ?? true }
                let plans = usable.compactMap { actor -> (SeasonPackManifest.Actor, Date)? in
                    // 앱을 열었을 때(이 실행·이번 복귀에서 아직 안 난 액터)는 기다리지 않고 바로 한 번 날린다. 그다음부터 3~5분 간격.
                    if lastFlights[actor.id] == nil { return (actor, host.now()) }
                    return throttle.nextFlight(ref: ref, now: host.now(), lastFlight: lastFlights[actor.id], interval: actor.intervalSeconds, reduced: false).map { (actor, $0) }
                }
                guard let (actor, at) = plans.min(by: { $0.1 < $1.1 }) else { return }
                try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSince(host.now()))))
                if Task.isCancelled { return }
                throttle.markFirstDemoShown(ref)
                lastFlights[actor.id] = host.now()
                await fly(actor, ref: ref, host: host)
            }
        }
    }

    private func fly(_ actor: SeasonPackManifest.Actor, ref: SeasonPackRef, host: any SeasonPackHost) async {
        flight = Flight(actor: actor, startedAt: host.now(), frozenProgress: nil, ref: ref)
        host.reportDemoState(.flightStarted(ref))
        round = Task { [weak self] in
            try? await Task.sleep(for: .seconds(actor.flight.seconds))
            guard !Task.isCancelled, let self, self.flight?.frozenProgress == nil else { return }
            self.flight = nil
        }
        await round?.value
        host.reportDemoState(.flightEnded(ref))
    }

    /// 산타를 눌렀다: 비행을 멈추고 그 자리에서 선물을 뿌린다(1.2초 뒤 사라짐).
    public func actorTapped(at point: CGPoint) {
        guard var current = flight, current.frozenProgress == nil, let center, let host = center.host else { return }
        let progress = min(max(host.now().timeIntervalSince(current.startedAt) / current.actor.flight.seconds, 0), 1)
        current.frozenProgress = progress
        flight = current
        round?.cancel()
        let images = current.actor.tap?.burst?.images ?? []
        let count = current.actor.tap?.burst?.count ?? 0
        burst = Burst(origin: point, startedAt: host.now(), images: images,
                      gifts: SeasonPackActorMath.gifts(count: count, imageCount: images.count, seed: UInt64(abs(Int(host.now().timeIntervalSince1970)))))
        host.reportDemoState(.giftsBurst(current.ref))
        round = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SeasonPackActorMath.burstSeconds))
            guard !Task.isCancelled else { return }
            self?.burst = nil
            self?.flight = nil
        }
    }

    /// 아무 데나 눌렀다: 그 회차 비행은 멈춘다(다음 회차는 그대로).
    public func stopRound() {
        guard flight != nil, flight?.frozenProgress == nil else { return }
        round?.cancel()
        flight = nil
    }

    /// 화면을 벗어나거나 앱이 뒤로 가면 소리·비행·가사를 멈춘다.
    public func stopAll() {
        flightLoop?.cancel(); lyricTask?.cancel(); blinkTask?.cancel(); round?.cancel()
        sound.stop()
        flight = nil; burst = nil; lyricText = nil; fastBlinkUntil = nil
    }

    func pause() {
        isPaused = true
        flightLoop?.cancel(); lyricTask?.cancel(); round?.cancel()
        sound.stop()
        flight = nil; burst = nil; lyricText = nil; fastBlinkUntil = nil
    }

    /// 앱으로 돌아오면 이펙트를 바로 한 번 보이고 3~5분 타이머를 새로 돈다.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        lastFlights.removeAll()
        startFlightLoop()
    }
}

/// 화면 전체 위로 날아가는 액터와 선물. 산타(44pt 이상)만 눌리고 나머지는 지도 제스처를 막지 않는다.
struct SeasonPackActorLayer: View {
    let center: SeasonPackCenter

    var body: some View {
        GeometryReader { proxy in
            let stage = center.stage
            ZStack(alignment: .topLeading) {
                if let flight = stage.flight, let pack = center.active, let image = SeasonPackImageCache.shared.image(pack: pack, asset: flight.actor.image) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: flight.frozenProgress != nil)) { context in
                        let progress = flight.frozenProgress ?? min(max(context.date.timeIntervalSince(flight.startedAt) / flight.actor.flight.seconds, 0), 1)
                        let point = SeasonPackActorMath.flightPoint(flight.actor.flight, progress: progress)
                        let size = CGSize(width: 128, height: 128 * CGFloat(image.height) / CGFloat(max(image.width, 1)))
                        let center = CGPoint(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                        Image(decorative: image, scale: 3)
                            .resizable().scaledToFit()
                            .frame(width: size.width, height: size.height)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .position(center)
                            .onTapGesture { stage.actorTapped(at: center) }
                    }
                }
                if let burst = stage.burst, let pack = center.active {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let seconds = context.date.timeIntervalSince(burst.startedAt)
                        if seconds < SeasonPackActorMath.burstSeconds {
                            ForEach(Array(burst.gifts.enumerated()), id: \.offset) { _, gift in
                                if burst.images.indices.contains(gift.image),
                                   let image = SeasonPackImageCache.shared.image(pack: pack, asset: burst.images[gift.image]) {
                                    let delta = SeasonPackActorMath.giftOffset(gift, at: seconds)
                                    Image(decorative: image, scale: 3)
                                        .resizable().scaledToFit().frame(width: 28, height: 28)
                                        .rotationEffect(.degrees(gift.spin * seconds * 90))
                                        .opacity(max(0, 1 - seconds / SeasonPackActorMath.burstSeconds * 0.6))
                                        .position(x: burst.origin.x + delta.dx * proxy.size.width, y: burst.origin.y + delta.dy * proxy.size.height)
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
