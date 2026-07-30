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

    var id: Self { self }
}
