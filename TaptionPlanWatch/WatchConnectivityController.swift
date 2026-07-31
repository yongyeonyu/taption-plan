import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    @Published private(set) var payload: TaptionWatchPayload?
    @Published private(set) var statusText = "iPhone 연결 중"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cachedPayloadKey = "TaptionPlan.cachedWatchPayload"

    override init() {
        super.init()
        restoreCachedPayload()
        guard WCSession.isSupported() else {
            statusText = "연결을 지원하지 않음"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let data = session.receivedApplicationContext[
            TaptionWatchEnvelope.payloadKey
        ] as? Data {
            apply(data: data)
        }
        updateStatus(
            activationRawValue: session.activationState.rawValue,
            isReachable: session.isReachable
        )
    }

    var orderedItems: [TaptionWatchPlanItem] {
        (payload?.items ?? []).sorted { $0.startsAt < $1.startsAt }
    }

    func currentItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        orderedItems.first { $0.status == "running" }
            ?? orderedItems.first { $0.startsAt <= date && date < $0.endsAt }
    }

    func nextItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        let currentID = currentItem(at: date)?.id
        return orderedItems.first {
            $0.id != currentID && $0.endsAt > date && $0.status == "planned"
        }
    }

    func send(_ kind: TaptionWatchCommandKind, for planID: UUID) {
        guard WCSession.isSupported(),
              let data = try? encoder.encode(
                TaptionWatchCommand(planID: planID, kind: kind)
              ) else {
            return
        }
        let envelope: [String: Any] = [TaptionWatchEnvelope.commandKey: data]
        let session = WCSession.default
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activationRawValue = session.activationState.rawValue
        let isReachable = session.isReachable
        let data = session.receivedApplicationContext[
            TaptionWatchEnvelope.payloadKey
        ] as? Data
        Task { @MainActor [weak self] in
            self?.updateStatus(
                activationRawValue: activationRawValue,
                isReachable: isReachable
            )
            if let data {
                self?.apply(data: data)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let activationRawValue = session.activationState.rawValue
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.updateStatus(
                activationRawValue: activationRawValue,
                isReachable: isReachable
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let data = applicationContext[TaptionWatchEnvelope.payloadKey] as? Data
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        let data = message[TaptionWatchEnvelope.payloadKey] as? Data
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
        }
    }

    private func apply(data: Data) {
        guard let value = try? decoder.decode(
                TaptionWatchPayload.self,
                from: data
              ) else {
            return
        }
        payload = value
        UserDefaults.standard.set(data, forKey: cachedPayloadKey)
    }

    private func restoreCachedPayload() {
        guard let data = UserDefaults.standard.data(forKey: cachedPayloadKey),
              let value = try? decoder.decode(
                TaptionWatchPayload.self,
                from: data
              ) else {
            return
        }
        payload = value
    }

    private func updateStatus(
        activationRawValue: Int,
        isReachable: Bool
    ) {
        switch activationRawValue {
        case WCSessionActivationState.notActivated.rawValue:
            statusText = "iPhone 연결 중"
        case WCSessionActivationState.inactive.rawValue:
            statusText = "연결 대기"
        case WCSessionActivationState.activated.rawValue:
            statusText = isReachable
                ? "iPhone 실시간 연결"
                : "백그라운드 동기화"
        default:
            statusText = "연결 상태 확인 중"
        }
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
