import AVFoundation
import CallKit
import Foundation
import MediaPlayer
import TaptionPlanCore
import UIKit

// MARK: - AirPods playback and call observations

enum AirPodsActivityKind: Sendable {
    case music
    case call
}

struct AirPodsActivityObservation: Equatable, Sendable {
    var id: UUID
    var kind: AirPodsActivityKind
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var routeName: String
}

/// Observes only short-lived, device-local activity. iOS does not expose a
/// call-history API, so call records are created while CallKit reports an
/// active call and an AirPods route is connected.
final class AirPodsActivityService: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    private let callObserver = CXCallObserver()
    private var routeObservers: [NSObjectProtocol] = []
    private var observesMusicPlayer = false
    private var handler: (@MainActor @Sendable (AirPodsActivityObservation) -> Void)?
    private var musicObservation: AirPodsActivityObservation?
    private var callObservation: AirPodsActivityObservation?
    private var activeCallID: UUID?
    private var isStarted = false

    deinit {
        stopObservers()
    }

    func start(
        onObservation: @escaping @MainActor @Sendable (AirPodsActivityObservation) -> Void
    ) {
        handler = onObservation
        guard !isStarted else {
            refresh()
            return
        }
        isStarted = true
        callObserver.setDelegate(self, queue: .main)
        let center = NotificationCenter.default
        routeObservers = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
            // 앱이 멈춘 동안 놓친 변화를 돌아올 때 맞춘다.
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
        ]
        refresh()
    }

    @discardableResult
    func stop(at date: Date = .now) -> [AirPodsActivityObservation] {
        let finished: [AirPodsActivityObservation] = [
            musicObservation,
            callObservation,
        ].compactMap { observation in
            guard let observation, observation.endedAt == nil else { return nil }
            var value = observation
            value.endedAt = max(observation.startedAt, date)
            return value
        }
        musicObservation = nil
        callObservation = nil
        activeCallID = nil
        stopObservers()
        return finished
    }

    func callObserver(
        _ callObserver: CXCallObserver,
        callChanged call: CXCall
    ) {
        refresh()
    }

    private func refresh(at date: Date = .now) {
        guard isStarted else { return }
        let output = AVAudioSession.sharedInstance().currentRoute.outputs
            .first(where: Self.isAirPodsOutput)
        guard let output else {
            setObservesMusicPlayer(false)
            finish(&musicObservation, at: date)
            finish(&callObservation, at: date)
            activeCallID = nil
            return
        }

        setObservesMusicPlayer(true)

        let routeName = output.portName
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let playbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = playbackRate > 0
            || MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
        if isPlaying {
            let title = Self.nowPlayingTitle(from: nowPlaying)
            if musicObservation?.title != title
                || musicObservation?.routeName != routeName {
                finish(&musicObservation, at: date)
                musicObservation = AirPodsActivityObservation(
                    id: UUID(),
                    kind: .music,
                    title: title,
                    startedAt: date,
                    endedAt: nil,
                    routeName: routeName
                )
                emit(musicObservation)
            }
        } else {
            finish(&musicObservation, at: date)
        }

        let activeCall = callObserver.calls.first { !$0.hasEnded }
        if let activeCall, activeCallID != activeCall.uuid {
            finish(&callObservation, at: date)
            activeCallID = activeCall.uuid
            callObservation = AirPodsActivityObservation(
                id: UUID(),
                kind: .call,
                title: "통화",
                startedAt: date,
                endedAt: nil,
                routeName: routeName
            )
            emit(callObservation)
        } else if activeCall == nil {
            finish(&callObservation, at: date)
            activeCallID = nil
        }
    }

    private func finish(
        _ observation: inout AirPodsActivityObservation?,
        at date: Date
    ) {
        guard let current = observation, current.endedAt == nil else {
            return
        }
        var value = current
        value.endedAt = max(current.startedAt, date)
        emit(value)
        observation = nil
    }

    private func emit(_ observation: AirPodsActivityObservation?) {
        guard let observation, let handler else { return }
        Task { @MainActor in
            handler(observation)
        }
    }

    /// 재생 알림은 켜 둔 동안에만 온다. AirPods가 연결된 동안만 켠다. 15초 타이머가 하던 일을 대신한다.
    private func setObservesMusicPlayer(_ observes: Bool) {
        guard observesMusicPlayer != observes else { return }
        observesMusicPlayer = observes
        let player = MPMusicPlayerController.systemMusicPlayer
        if observes {
            player.beginGeneratingPlaybackNotifications()
        } else {
            player.endGeneratingPlaybackNotifications()
        }
    }

    private func stopObservers() {
        setObservesMusicPlayer(false)
        let center = NotificationCenter.default
        routeObservers.forEach(center.removeObserver)
        routeObservers.removeAll()
        isStarted = false
    }

    private static func isAirPodsOutput(_ output: AVAudioSessionPortDescription) -> Bool {
        let name = output.portName.localizedCaseInsensitiveContains("airpods")
        let bluetooth = output.portType == .bluetoothA2DP
            || output.portType == .bluetoothHFP
            || output.portType == .bluetoothLE
        return name && bluetooth
    }

    private static func nowPlayingTitle(
        from info: [String: Any]?
    ) -> String {
        let title = info?[MPMediaItemPropertyTitle] as? String
        let artist = info?[MPMediaItemPropertyArtist] as? String
        let values: [String] = [title, artist].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? "음악 재생" : values.joined(separator: " · ")
    }
}
