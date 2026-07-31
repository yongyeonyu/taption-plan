import SwiftUI

@main
struct TaptionPlanWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityController()
    @StateObject private var workout = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivity)
                .environmentObject(workout)
        }
    }
}
