import Foundation
import TaptionPlanCore

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case running
    case completed
    case skipped
}

enum PlanOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case repeatRule
    case calendar
    case health
    case photo
    case location
    case motion
}

enum GoalCategoryPolicy {
    static let systemSelectableCategoryIDs: Set<String> = [
        "movement",
        "location",
        "sleep",
        "activity",
        "appUsage",
    ]
}

struct PlanRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var span: TimeSpan
    var categoryID: String
    var middleCategoryName: String?
    var subCategoryName: String?
    var repeatRules: [GoalRepeatRule]?
    var parentID: UUID?
    var status: PlanStatus
    var origin: PlanOrigin
    var isFixed: Bool
    var isImportant: Bool
    var externalCalendarID: String?
    var externalEventID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        span: TimeSpan,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        repeatRules: [GoalRepeatRule]? = nil,
        parentID: UUID? = nil,
        status: PlanStatus = .planned,
        origin: PlanOrigin = .user,
        isFixed: Bool = false,
        isImportant: Bool = false,
        externalCalendarID: String? = nil,
        externalEventID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.span = span
        self.categoryID = categoryID
        self.middleCategoryName = middleCategoryName
        self.subCategoryName = subCategoryName
        self.repeatRules = repeatRules?.isEmpty == false ? repeatRules : nil
        self.parentID = parentID
        self.status = status
        self.origin = origin
        self.isFixed = isFixed
        self.isImportant = isImportant
        self.externalCalendarID = externalCalendarID
        self.externalEventID = externalEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PlanRecord {
    /// Plans use the same semantic vocabulary as automatic records.  The
    /// routine/action distinction remains an origin relationship in the graph.
    var semanticLevel: TimelineSemanticLevel {
        middleCategoryName?.isEmpty == false
            || subCategoryName?.isEmpty == false
            ? .activity
            : .dayPhase
    }

    var sourceKind: TimelineSourceKind {
        GoalRecordPolicy.isGoal(self) ? .routine : .action
    }
}

struct GoalRepeatRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String?
    var weekdays: Set<Int>
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    init(
        id: UUID = UUID(),
        name: String? = nil,
        weekdays: Set<Int>,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }
}
