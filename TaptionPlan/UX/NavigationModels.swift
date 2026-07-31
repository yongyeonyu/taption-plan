import Foundation

enum TaptionDeepLink: Equatable {
    case today
    case plan(UUID)
    case catPicker

    init?(url: URL) {
        guard url.scheme?.lowercased() == "taptionplan" else { return nil }
        switch url.host {
        case "today":
            self = .today
        case "plan":
            let components = url.pathComponents.filter { $0 != "/" }
            guard let rawID = components.first,
                  let id = UUID(uuidString: rawID) else {
                return nil
            }
            self = .plan(id)
        case "cats":
            self = .catPicker
        default:
            return nil
        }
    }
}

enum AddPlanContext: Equatable {
    case quick
    case goal
    case child(UUID)

    var isGoal: Bool {
        if case .goal = self { return true }
        return false
    }

    var parentID: UUID? {
        if case .child(let id) = self { return id }
        return nil
    }
}

enum AppDetail: Equatable {
    case group
    case locationTimeline
    case memo
    case inference
    case catPicker
    case categoryManager
    case onboarding
    case templateReview
    case widgetPreview
}

struct QuickActionItem: Identifiable {
    let id = UUID()
    let planID: UUID?
    let title: String
    let time: String
    let context: String

    init(
        planID: UUID? = nil,
        title: String,
        time: String,
        context: String
    ) {
        self.planID = planID
        self.title = title
        self.time = time
        self.context = context
    }
}

struct PlanEditorRequest: Identifiable, Equatable {
    let id: UUID
}

enum ReviewScale: String, CaseIterable, Identifiable {
    case week = "주"
    case month = "월"
    case year = "년"

    var id: Self { self }
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

    var timelineLevel: TimelineLevel {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    var narrower: TimeScale? {
        switch self {
        case .year: .month
        case .month: .week
        case .week: .day
        case .day: nil
        }
    }

    var broader: TimeScale? {
        switch self {
        case .year: nil
        case .month: .year
        case .week: .month
        case .day: .week
        }
    }
}

struct ScheduleHeaderFormatter {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func title(for date: Date, scale: TimeScale) -> String {
        switch scale {
        case .day:
            return format(date, pattern: "M월 d일 (E)")
        case .week:
            let span = TimelineAggregationEngine(
                calendar: calendar
            ).interval(for: .week, containing: date)
            return "\(format(span.start, pattern: "M월 d일")) – \(format(span.end.addingTimeInterval(-1), pattern: "M월 d일"))"
        case .month:
            return format(date, pattern: "yyyy년 M월")
        case .year:
            return format(date, pattern: "yyyy년")
        }
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
