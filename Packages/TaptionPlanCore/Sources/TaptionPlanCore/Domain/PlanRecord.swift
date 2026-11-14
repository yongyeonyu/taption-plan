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

/// 일정의 장소(PLB1114A18): 이름과 좌표.
public struct PlanPlace: Codable, Hashable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
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
    /// 일정의 장소와 예상 지출(원, 0보다 큰 값만)(PLB1114A18). 없으면 키를 쓰지 않아 예전 저장 바이트가 그대로다.
    public var place: PlanPlace?
    public var plannedSpendKRW: Double?

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
        updatedAt: Date = .now,
        place: PlanPlace? = nil,
        plannedSpendKRW: Double? = nil
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
        self.place = place
        self.plannedSpendKRW = plannedSpendKRW
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
