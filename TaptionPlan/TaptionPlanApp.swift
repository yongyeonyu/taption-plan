import SwiftData
import SwiftUI

@main
struct TaptionPlanApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
        .modelContainer(for: PlanItem.self)
    }
}
