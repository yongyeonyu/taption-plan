import Foundation
import SwiftData

@Model
final class PlanItem {
    var id: UUID = UUID()
    var title: String = ""
    var startAt: Date = Date.now
    var endAt: Date = Date.now.addingTimeInterval(3_600)
    var categoryRawValue: String = PlanCategory.project.rawValue
    var memo: String?
    var isCompleted: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var parent: PlanItem?

    @Relationship(deleteRule: .nullify, inverse: \PlanItem.parent)
    var children: [PlanItem]? = []

    init(
        title: String,
        startAt: Date,
        endAt: Date,
        category: PlanCategory,
        memo: String? = nil,
        parent: PlanItem? = nil
    ) {
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.categoryRawValue = category.rawValue
        self.memo = memo
        self.parent = parent
    }

    var category: PlanCategory {
        PlanCategory(rawValue: categoryRawValue) ?? .project
    }

    var duration: TimeInterval {
        max(0, endAt.timeIntervalSince(startAt))
    }
}

enum PlanCategory: String, CaseIterable, Identifiable {
    case movement = "이동"
    case location = "위치"
    case activity = "활동"
    case photo = "사진"
    case project = "프로젝트"
    case exercise = "운동"
    case study = "학습"
    case hobby = "취미"
    case sleep = "수면"
    case routine = "생활"
    case relationship = "관계"
    case rest = "휴식"
    case travel = "여행"
    case health = "건강"
    case event = "이벤트"

    var id: Self { self }

    init(categoryID: String) {
        switch categoryID {
        case "movement": self = .movement
        case "location": self = .location
        case "activity": self = .activity
        case "photo": self = .photo
        case "exercise": self = .exercise
        case "study": self = .study
        case "hobby": self = .hobby
        case "sleep": self = .sleep
        case "routine": self = .routine
        case "relationship": self = .relationship
        case "rest": self = .rest
        case "travel": self = .travel
        case "health": self = .health
        case "event": self = .event
        default: self = .project
        }
    }

    var categoryID: String {
        switch self {
        case .movement: "movement"
        case .location: "location"
        case .activity: "activity"
        case .photo: "photo"
        case .project: "project"
        case .exercise: "exercise"
        case .study: "study"
        case .hobby: "hobby"
        case .sleep: "sleep"
        case .routine: "routine"
        case .relationship: "relationship"
        case .rest: "rest"
        case .travel: "travel"
        case .health: "health"
        case .event: "event"
        }
    }
}
