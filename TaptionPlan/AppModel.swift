import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedTab: RootTab = .schedule
    var selectedScale: TimeScale = .day
    var isAddPlanPresented = false
}

enum RootTab: String, CaseIterable, Identifiable {
    case schedule = "시간표"
    case goals = "목표"
    case review = "회고"
    case settings = "설정"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .schedule: "chart.bar.xaxis"
        case .goals: "scope"
        case .review: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum TimeScale: String, CaseIterable, Identifiable {
    case day = "일"
    case week = "주"
    case month = "월"
    case year = "년"

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "오늘"
        case .week: "이번 주"
        case .month: "이번 달"
        case .year: "올해"
        }
    }

    var axisLabels: [String] {
        switch self {
        case .day: ["06", "09", "12", "15", "18", "21"]
        case .week: ["월", "화", "수", "목", "금", "토", "일"]
        case .month: ["1", "5", "10", "15", "20", "25", "30"]
        case .year: ["1", "3", "5", "7", "9", "11", "12"]
        }
    }
}
