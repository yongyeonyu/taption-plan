import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    @Published private(set) var payload: TaptionWatchPayload?
    @Published private(set) var statusText = "iPhone 연결 중"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cachedPayloadKey = "TaptionPlan.cachedWatchPayload"
    private let pendingSensorSummariesKey =
        "TaptionPlan.pendingWatchSensorSummaries"
    private let pendingHealthSnapshotsKey =
        "TaptionPlan.pendingWatchHealthSnapshots"
    private var pendingSensorSummaries: [TaptionWatchSensorSummary] = []
    private var pendingHealthSnapshots: [TaptionWatchHealthSnapshot] = []
    private var widgetReloadFollowupTask: Task<Void, Never>?
    private var handledWorkoutRequestIDs = Set<UUID>()
    var onWorkoutRequest: ((TaptionWatchWorkoutRequest) -> Void)?
    var onPayloadChange: ((TaptionWatchPayload) -> Void)?
    var onDataSyncRequest: (() -> Void)?

    private var didPrepare = false

    override init() {
        super.init()
    }

    /// 캐시 복원과 WatchConnectivity 활성화는 첫 화면이 그려진 뒤에 한다.
    /// App.init에서 수행하면 실기기에서 첫 프레임 전에 위젯·앱그룹·WC
    /// 데몬을 모두 건드리게 된다.
    func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        restoreCachedPayload()
        restorePendingSensorSummaries()
        restorePendingHealthSnapshots()
        guard WCSession.isSupported() else {
            statusText = "연결을 지원하지 않음"
            return
        }
        // WCSession.delegate는 weak 참조다. SwiftUI가 소유권을 넘기기 전에
        // 해제되면 세션이 델리게이트 없는 상태로 남으므로 강한 참조를 둔다.
        Self.activeDelegate = self
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private static var activeDelegate: WatchConnectivityController?

    var orderedItems: [TaptionWatchPlanItem] {
        (payload?.items ?? []).sorted { $0.startsAt < $1.startsAt }
    }

    /// The payload can be cached while the Watch is offline. Re-apply the
    /// live-window policy at read time so a stale cache never resurrects a
    /// completed or already-ended item on the Watch.
    func liveItems(at date: Date = .now) -> [TaptionWatchPlanItem] {
        orderedItems.filter {
            TaptionWatchLiveItemPolicy.isLive($0, at: date)
        }
    }

    func currentItems(at date: Date = .now) -> [TaptionWatchPlanItem] {
        TaptionWatchLiveItemPolicy.current(liveItems(at: date), at: date)
    }

    func upcomingItems(at date: Date = .now) -> [TaptionWatchPlanItem] {
        TaptionWatchLiveItemPolicy.upcoming(liveItems(at: date), at: date)
    }

    func currentItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        currentItems(at: date).first
    }

    func nextItem(at date: Date = .now) -> TaptionWatchPlanItem? {
        upcomingItems(at: date).first
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
        // 활성화 전 전송은 예외를 던진다.
        guard session.activationState == .activated else { return }
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

        // Keep the reliable request independent from the live request.  A
        // WatchConnectivity reply/error callback may arrive on its private
        // operation queue; closures created from this @MainActor type then
        // trip Swift 6's actor-isolation precondition before their body runs.
        // The iPhone publishes its latest payload when it receives either
        // form of the refresh request, so no callback is needed here.
        session.transferUserInfo(request)
        if session.isReachable {
            session.sendMessage(
                request,
                replyHandler: nil,
                errorHandler: nil
            )
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

    func sendHealthSnapshot(_ snapshot: TaptionWatchHealthSnapshot) {
        guard WCSession.isSupported(),
              let data = try? encoder.encode(snapshot) else {
            return
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.healthSnapshotKey: data,
        ]
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(snapshot)
            return
        }
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
            if activationState == .activated {
                self?.flushPendingSensorSummaries(using: .default)
                self?.flushPendingHealthSnapshots(using: .default)
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
        let workoutData = message[
            TaptionWatchEnvelope.workoutRequestKey
        ] as? Data
        let dataSyncRequested = message[
            TaptionWatchEnvelope.dataSyncRequestKey
        ] as? Bool == true
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                self?.onDataSyncRequest?()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let data = userInfo[TaptionWatchEnvelope.payloadKey] as? Data
        let workoutData = userInfo[
            TaptionWatchEnvelope.workoutRequestKey
        ] as? Data
        let dataSyncRequested = userInfo[
            TaptionWatchEnvelope.dataSyncRequestKey
        ] as? Bool == true
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                self?.onDataSyncRequest?()
            }
        }
    }

    private func applyWorkoutRequest(data: Data) {
        guard let request = try? decoder.decode(
            TaptionWatchWorkoutRequest.self,
            from: data
        ), handledWorkoutRequestIDs.insert(request.id).inserted else {
            return
        }
        if handledWorkoutRequestIDs.count > 100 {
            handledWorkoutRequestIDs = [request.id]
        }
        onWorkoutRequest?(request)
    }

    private func apply(data: Data) {
        guard let value = try? decoder.decode(
                TaptionWatchPayload.self,
                from: data
              ) else {
            return
        }
        payload = value
        onPayloadChange?(value)
        UserDefaults.standard.set(data, forKey: cachedPayloadKey)
        publishToWidget(value)
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
        publishToWidget(value)
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
        onPayloadChange?(value)
        publishToWidget(value)
    }

    private func publishToWidget(_ payload: TaptionWatchPayload) {
        guard (try? TaptionWatchWidgetStore.write(payload)) != nil else {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWatchWidgetKind.status)
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(
                ofKind: TaptionWatchWidgetKind.status
            )
        }
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

    private func cachePending(_ snapshot: TaptionWatchHealthSnapshot) {
        pendingHealthSnapshots.removeAll { $0.capturedAt == snapshot.capturedAt }
        pendingHealthSnapshots.append(snapshot)
        pendingHealthSnapshots.sort { $0.capturedAt < $1.capturedAt }
        if pendingHealthSnapshots.count > 20 {
            pendingHealthSnapshots.removeFirst(pendingHealthSnapshots.count - 20)
        }
        persistPendingHealthSnapshots()
    }

    private func flushPendingHealthSnapshots(using session: WCSession) {
        guard session.activationState == .activated,
              !pendingHealthSnapshots.isEmpty else { return }
        let pending = pendingHealthSnapshots
        pendingHealthSnapshots = []
        persistPendingHealthSnapshots()
        for snapshot in pending {
            sendHealthSnapshot(snapshot)
        }
    }

    private func restorePendingHealthSnapshots() {
        guard let data = UserDefaults.standard.data(
            forKey: pendingHealthSnapshotsKey
        ),
        let values = try? decoder.decode(
            [TaptionWatchHealthSnapshot].self,
            from: data
        ) else { return }
        pendingHealthSnapshots = values
    }

    private func persistPendingHealthSnapshots() {
        if pendingHealthSnapshots.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingHealthSnapshotsKey)
            return
        }
        guard let data = try? encoder.encode(pendingHealthSnapshots) else {
            return
        }
        UserDefaults.standard.set(data, forKey: pendingHealthSnapshotsKey)
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
