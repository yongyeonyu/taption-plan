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
