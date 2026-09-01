import SwiftUI

@main
struct TaptionPlanWatchApp: App {
    @StateObject private var connectivity: WatchConnectivityController
    @StateObject private var workout: WatchWorkoutManager

    init() {
        // 워치 앱은 iPhone 앱과 별도로 업데이트되어 뒤처질 수 있다.
        // 어느 빌드가 실제로 돌고 있는지 기록에 남긴다.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        WatchLaunchDiagnostics.mark("build \(build ?? "unknown")")
        WatchLaunchDiagnostics.mark("app-init-begin")
        let connectivity = WatchConnectivityController()
        let workout = WatchWorkoutManager()
        workout.onSensorSummary = { [weak connectivity] summary in
            connectivity?.sendSensorSummary(summary)
        }
        workout.onAmbientSensorSummary = { [weak connectivity] summary in
            await connectivity?.sendSensorSummaryAndWait(summary)
        }
        workout.onAccelerationChunk = { [weak connectivity] chunk in
            await connectivity?.sendAccelerationChunkAndWait(chunk)
        }
        workout.onHealthSnapshot = { [weak connectivity] snapshot in
            connectivity?.sendHealthSnapshot(snapshot)
        }
        connectivity.onPayloadChange = { [weak workout] payload in
            workout?.applySettings(
                acceleration: payload.accelerationSettings,
                dataSyncProfile: payload.dataSyncProfile
            )
        }
        connectivity.onDataSyncRequest = { [weak connectivity, weak workout] requestID in
            Task { @MainActor in
                guard let workout else {
                    connectivity?.finishDataSyncRequest(requestID)
                    return
                }
                await workout.syncNow(requestID: requestID)
                connectivity?.finishDataSyncRequest(requestID)
            }
        }
        connectivity.onWorkoutRequest = {
            [weak connectivity, weak workout] request in
            guard let workout else { return }
            Task { @MainActor in
                switch request.action {
                case .start:
                    let linkedPlan = request.linkedPlanID.flatMap { planID in
                        connectivity?.orderedItems.first { $0.id == planID }
                    }
                    _ = await workout.start(
                        kind: request.kind,
                        linkedPlan: linkedPlan,
                        sessionID: request.sessionID
                    )
                case .stop:
                    if workout.isActive {
                        _ = await workout.stop()
                    }
                }
            }
        }
        connectivity.activateConnectivity()
        _connectivity = StateObject(wrappedValue: connectivity)
        _workout = StateObject(wrappedValue: workout)
        WatchLaunchDiagnostics.mark("app-init-end")
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivity)
                .environmentObject(workout)
        }
    }
}
