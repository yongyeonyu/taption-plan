import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedTab: RootTab = .schedule
    var selectedScale: TimeScale = .day
    var isAddPlanPresented = false
    var selectedAction: QuickActionItem?
    var detail: AppDetail?
    var selectedCatCoat: CatCoat = .calico
    var reviewScale: ReviewScale = .week

    var showsBottomBar: Bool {
        switch detail {
        case nil, .group, .locationTimeline:
            true
        default:
            false
        }
    }

    func selectTab(_ tab: RootTab) {
        selectedTab = tab
        detail = nil
    }
}
