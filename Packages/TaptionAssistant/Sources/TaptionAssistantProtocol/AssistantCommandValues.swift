import Foundation

public struct AssistantCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 고칠 일정. `planId`가 없으면 그날 `startTime`에 시작하는 일정을 찾는다.
public struct AssistantPlanTarget: Equatable, Sendable {
    public var planID: String?
    public var startTime: Date?

    public init(planID: String? = nil, startTime: Date? = nil) {
        self.planID = planID
        self.startTime = startTime
    }
}

/// 일정의 분류·중요·상위 루틴(ACT1114A07). nil인 칸은 그대로 둔다. `parentGoalID`가 빈 글이면 루틴에서 뗀다.
public struct AssistantScheduleExtras: Equatable, Sendable {
    public var categoryID: String?
    public var important: Bool?
    public var parentGoalID: String?

    public init(categoryID: String? = nil, important: Bool? = nil, parentGoalID: String? = nil) {
        self.categoryID = categoryID
        self.important = important
        self.parentGoalID = parentGoalID
    }

    public var isEmpty: Bool { self == Self() }
}

/// 일정의 새 시각. ISO 시각이거나, 그 일정 날의 HH:mm.
public enum AssistantScheduleTime: Equatable, Sendable {
    case instant(Date)
    case clock(hour: Int, minute: Int)

    public init?(text: String) {
        if let date = AssistantCommandParser.instant(text) {
            self = .instant(date)
            return
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self = .clock(hour: hour, minute: minute)
    }

    public func resolve(on day: Date, calendar: Calendar) -> Date? {
        switch self {
        case let .instant(date): date
        case let .clock(hour, minute): calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
    }
}

/// 날짜(`YYYY-MM-DD`)·시각(자정부터의 분)을 따로 옮긴다(ACT1114A07). 날짜만 주면 시각을, 시각만 주면 날짜를 그대로 둔다.
public struct AssistantWhenChange: Equatable, Sendable {
    public var date: String?
    public var minutes: Int?

    public var isEmpty: Bool { date == nil && minutes == nil }

    public init(date: String? = nil, minutes: Int? = nil) {
        self.date = date
        self.minutes = minutes
    }

    /// 명령의 `date`·`time`에서. 준 칸이 틀리면 nil.
    public init?(date: String?, time: String?, calendar: Calendar) {
        if let date, AssistantCommandParser.day(date, calendar: calendar) == nil { return nil }
        let minutes = time.flatMap(AssistantCommandParser.minutes)
        if time != nil, minutes == nil { return nil }
        self.init(date: date, minutes: minutes)
    }

    public func applied(to instant: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard !isEmpty else { return instant }
        let day = date.flatMap { AssistantCommandParser.day($0, calendar: calendar) } ?? calendar.startOfDay(for: instant)
        let clock = minutes ?? calendar.component(.hour, from: instant) * 60 + calendar.component(.minute, from: instant)
        return calendar.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: day) ?? instant
    }
}
