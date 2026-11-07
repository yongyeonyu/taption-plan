import Foundation

public enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case running
    case completed
    case skipped
}

public enum PlanOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case repeatRule
    case calendar
    case health
    case photo
    case location
    case motion
}

public struct PlanRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var span: TimeSpan
    public var categoryID: String
    public var middleCategoryName: String?
    public var subCategoryName: String?
    public var repeatRules: [GoalRepeatRule]?
    public var parentID: UUID?
    public var status: PlanStatus
    public var origin: PlanOrigin
    public var isFixed: Bool
    public var isImportant: Bool
    public var externalCalendarID: String?
    public var externalEventID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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

public struct GoalRepeatRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String?
    public var weekdays: Set<Int>
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int

    public init(
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
