import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    @Published private(set) var payload: TaptionWatchPayload?
    @Published private(set) var statusText = "iPhone 연결 중"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cachedPayloadKey = "TaptionPlan.cachedWatchPayload"
    private let pendingSensorSummariesKey =
        "TaptionPlan.pendingWatchSensorSummaries"
    private var pendingSensorSummaries: [TaptionWatchSensorSummary] = []

    override init() {
        super.init()
        restoreCachedPayload()
        restorePendingSensorSummaries()
        guard WCSession.isSupported() else {
            statusText = "연결을 지원하지 않음"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var orderedItems: [TaptionWatchPlanItem] {
        (payload?.items ?? []).sorted { $0.startsAt < $1.startsAt }
    }

    func currentItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        orderedItems.first { $0.status == "running" }
            ?? orderedItems.first {
                $0.status == "planned"
                    && $0.startsAt <= date
                    && date < $0.endsAt
            }
    }

    func nextItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        let currentID = currentItem(at: date)?.id
        return orderedItems.first {
            $0.id != currentID && $0.endsAt > date && $0.status == "planned"
        }
    }

    func send(_ kind: TaptionWatchCommandKind, for planID: UUID) {
        let command = TaptionWatchCommand(planID: planID, kind: kind)
        guard WCSession.isSupported(),
              let data = try? encoder.encode(command) else {
            return
        }
        applyOptimistic(command)
        let envelope: [String: Any] = [TaptionWatchEnvelope.commandKey: data]
        let session = WCSession.default
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    func requestSync() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let request: [String: Any] = [
            TaptionWatchEnvelope.refreshRequestKey: true,
        ]
        if session.isReachable {
            session.sendMessage(
                request,
                replyHandler: { [weak self] reply in
                    guard let data = reply[
                        TaptionWatchEnvelope.payloadKey
                    ] as? Data else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.apply(data: data)
                    }
                },
                errorHandler: { _ in
                    session.transferUserInfo(request)
                }
            )
        } else {
            session.transferUserInfo(request)
        }
    }

    func sendSensorSummary(_ summary: TaptionWatchSensorSummary) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(summary)
            return
        }
        transfer(summary, through: session)
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
            if activationState == .activated {
                self?.flushPendingSensorSummaries(using: .default)
                self?.requestSync()
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
            if isReachable {
                self?.requestSync()
            }
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

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let data = userInfo[TaptionWatchEnvelope.payloadKey] as? Data
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

    private func applyOptimistic(_ command: TaptionWatchCommand) {
        guard var value = payload,
              let index = value.items.firstIndex(where: {
                  $0.id == command.planID
              }) else {
            return
        }
        switch command.kind {
        case .start:
            value.items[index].status = "running"
            value.items[index].actualStartedAt = command.requestedAt
        case .complete, .stopCurrentActivity:
            value.items[index].status = "completed"
            value.items[index].actualStartedAt = nil
        case .skip:
            value.items[index].status = "skipped"
            value.items[index].actualStartedAt = nil
        case .postponeThirtyMinutes:
            value.items[index].startsAt = value.items[index].startsAt
                .addingTimeInterval(30 * 60)
            value.items[index].endsAt = value.items[index].endsAt
                .addingTimeInterval(30 * 60)
        }
        value.generatedAt = .now
        payload = value
        if let data = try? encoder.encode(value) {
            UserDefaults.standard.set(data, forKey: cachedPayloadKey)
        }
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

    private func transfer(
        _ summary: TaptionWatchSensorSummary,
        through session: WCSession
    ) {
        guard let data = try? encoder.encode(summary) else { return }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.sensorSummaryKey: data,
        ]
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    private func cachePending(_ summary: TaptionWatchSensorSummary) {
        pendingSensorSummaries.removeAll {
            $0.sessionID == summary.sessionID
                && $0.sequence == summary.sequence
        }
        pendingSensorSummaries.append(summary)
        pendingSensorSummaries.sort {
            if $0.startedAt == $1.startedAt {
                return $0.sequence < $1.sequence
            }
            return $0.startedAt < $1.startedAt
        }
        if pendingSensorSummaries.count > 40 {
            pendingSensorSummaries.removeFirst(
                pendingSensorSummaries.count - 40
            )
        }
        persistPendingSensorSummaries()
    }

    private func flushPendingSensorSummaries(using session: WCSession) {
        guard session.activationState == .activated,
              !pendingSensorSummaries.isEmpty else {
            return
        }
        let pending = pendingSensorSummaries
        pendingSensorSummaries = []
        persistPendingSensorSummaries()
        for summary in pending {
            transfer(summary, through: session)
        }
    }

    private func restorePendingSensorSummaries() {
        guard let data = UserDefaults.standard.data(
            forKey: pendingSensorSummariesKey
        ),
        let values = try? decoder.decode(
            [TaptionWatchSensorSummary].self,
            from: data
        ) else {
            return
        }
        pendingSensorSummaries = values
    }

    private func persistPendingSensorSummaries() {
        if pendingSensorSummaries.isEmpty {
            UserDefaults.standard.removeObject(
                forKey: pendingSensorSummariesKey
            )
            return
        }
        guard let data = try? encoder.encode(pendingSensorSummaries) else {
            return
        }
        UserDefaults.standard.set(
            data,
            forKey: pendingSensorSummariesKey
        )
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
