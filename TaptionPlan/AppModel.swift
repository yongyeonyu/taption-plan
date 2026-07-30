import Foundation
import Observation
import SwiftUI

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

enum AppDetail: Equatable {
    case group
    case locationTimeline
    case memo
    case inference
    case catPicker
    case onboarding
    case templateReview
    case widgetPreview
}

struct QuickActionItem: Identifiable {
    let id = UUID()
    let title: String
    let time: String
    let context: String
}

enum ReviewScale: String, CaseIterable, Identifiable {
    case week = "주"
    case month = "월"
    case year = "년"

    var id: Self { self }
}

enum CatCoat: String, CaseIterable, Identifiable {
    case white = "흰색 고양이"
    case calico = "삼색 고양이"
    case mackerel = "고등어 고양이"
    case black = "검정 고양이"
    case gray = "회색 고양이"
    case cheese = "치즈 고양이"
    case cow = "젖소무늬 고양이"

    var id: Self { self }

    var shortName: String {
        rawValue.replacingOccurrences(of: " 고양이", with: "")
    }

    var caption: String {
        switch self {
        case .white: "깨끗한 흰 털"
        case .calico: "흰색 · 검정 · 주황"
        case .mackerel: "회갈색 줄무늬"
        case .black: "노란 눈 · 검은 털"
        case .gray: "차분한 회색 털"
        case .cheese: "주황색 줄무늬"
        case .cow: "흰색 · 검정 얼룩"
        }
    }

    var baseColor: Color {
        switch self {
        case .white: Color(red: 1, green: 0.996, blue: 0.98)
        case .calico: Color(red: 0.97, green: 0.95, blue: 0.91)
        case .mackerel: Color(red: 0.56, green: 0.58, blue: 0.60)
        case .black: Color(red: 0.13, green: 0.13, blue: 0.14)
        case .gray: Color(red: 0.64, green: 0.65, blue: 0.67)
        case .cheese: Color(red: 0.90, green: 0.63, blue: 0.30)
        case .cow: Color(red: 1, green: 0.996, blue: 0.98)
        }
    }
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
        case .year: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
        }
    }
}
