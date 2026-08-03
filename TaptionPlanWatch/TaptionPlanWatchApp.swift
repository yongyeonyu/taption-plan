import SwiftUI

@main
struct TaptionPlanWatchApp: App {
    @StateObject private var connectivity: WatchConnectivityController
    @StateObject private var workout: WatchWorkoutManager

    init() {
        let connectivity = WatchConnectivityController()
        let workout = WatchWorkoutManager()
        workout.onSensorSummary = { [weak connectivity] summary in
            connectivity?.sendSensorSummary(summary)
        }
        workout.onHealthSnapshot = { [weak connectivity] snapshot in
            connectivity?.sendHealthSnapshot(snapshot)
        }
        workout.applySettings(
            acceleration: connectivity.payload?.accelerationSettings,
            dataSyncProfile: connectivity.payload?.dataSyncProfile
        )
        connectivity.onPayloadChange = { [weak workout] payload in
            workout?.applySettings(
                acceleration: payload.accelerationSettings,
                dataSyncProfile: payload.dataSyncProfile
            )
        }
        connectivity.onDataSyncRequest = { [weak workout] in
            Task { @MainActor in
                guard let workout else { return }
                await workout.syncNow()
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
        _connectivity = StateObject(wrappedValue: connectivity)
        _workout = StateObject(wrappedValue: workout)
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivity)
                .environmentObject(workout)
        }
    }
}
