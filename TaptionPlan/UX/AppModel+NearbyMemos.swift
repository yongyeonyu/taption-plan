import Foundation

extension AppModel {
    /// 저장이 이어져도 마지막 한 번만 맞춘다. 저장을 기다리게 하지 않는다.
    func scheduleNearbyMemoSync() {
        // 같은 때에 도착 알림 예약도 다시 맞춘다(ARN1114A17).
        ArrivalCardManager.shared.scheduleAlertSync(model: self)
        nearbyMemoSyncTask?.cancel()
        nearbyMemoSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNearbyMemoNotifications()
        }
    }

    func syncNearbyMemoNotifications() async {
        // 불러오기 전의 빈 기록으로 맞추면 등록해 둔 알림이 모두 지워진다.
        guard isBootstrapped, !repositoryLoadFailed, !isDeletingUserData else { return }
        let state = await NearbyMemoAvailability.current()
        guard let summary = await nearbyMemoScheduler.synchronize(
            memos: snapshot.memos,
            availability: state.availability,
            coordinate: state.coordinate,
            hidesText: securityStatus.settings.lockOnLaunch || securityStatus.settings.lockOnForeground
        ) else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "nearby_memo_sync",
            level: summary.failed > 0 ? .error : .info,
            fields: ["availability": String(describing: summary.availability)],
            metrics: [
                "desired": Double(summary.desired),
                "pending": Double(summary.pending),
                "failed": Double(summary.failed),
                "fired": Double(summary.fired)
            ]
        )
    }
}
