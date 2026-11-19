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

/// 일정의 장소(RMN1114A22): 이름과 AI가 준 좌표. 좌표는 받기만 하고 돌려보내지 않는다.
public struct AssistantSchedulePlace: Equatable, Sendable {
    public static let maximumNameLength = 100

    public var name: String
    public var coordinate: AssistantCoordinate

    /// 이름·위도·경도 셋이 함께이고 범위 안이어야 한다(서버와 같은 규칙).
    public init?(name: String?, latitude: Double?, longitude: Double?) {
        guard let name = AssistantCommandParser.clean(name, max: Self.maximumNameLength), let latitude, let longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.name = name
        self.coordinate = AssistantCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// 일정의 분류·중요·상위 루틴(ACT1114A07)과 장소·예상 지출(RMN1114A22). nil인 칸은 그대로 둔다. `parentGoalID`가 빈 글이면 루틴에서 뗀다.
public struct AssistantScheduleExtras: Equatable, Sendable {
    /// 예상 지출 상한(원). 가계부 금액 칸과 같다.
    public static let maximumPlannedSpend = 1e10

    public var categoryID: String?
    /// 상세분류 id(예: `activity.performanceMovie`). 대분류를 함께 정하고 일정의 중분류 이름으로 남는다(addSchedule만, NTR1119A02).
    public var detailID: String?
    public var important: Bool?
    public var parentGoalID: String?
    public var place: AssistantSchedulePlace?
    /// 예상 지출(원). 0 초과.
    public var plannedSpend: Double?
    /// 참이면 장소를 지운다(고칠 때만).
    public var clearPlace = false

    public init(
        categoryID: String? = nil, important: Bool? = nil, parentGoalID: String? = nil,
        place: AssistantSchedulePlace? = nil, plannedSpend: Double? = nil, clearPlace: Bool = false, detailID: String? = nil
    ) {
        self.categoryID = categoryID
        self.detailID = detailID
        self.important = important
        self.parentGoalID = parentGoalID
        self.place = place
        self.plannedSpend = plannedSpend
        self.clearPlace = clearPlace
    }

    /// 보낸 칸으로 장소·예상 지출을 읽는다. 틀린 칸이 있으면 false를 돌려주고 값을 바꾸지 않는다.
    /// 장소는 이름·위도·경도 셋이 함께, 지우기는 `true`만 받고 새 장소와 함께 보낼 수 없다.
    public mutating func readSpot(
        placeName: String?, latitude: Double?, longitude: Double?, plannedSpend: Double?, clearPlace: Bool?, allowsClear: Bool
    ) -> Bool {
        var place: AssistantSchedulePlace?
        if placeName != nil || latitude != nil || longitude != nil {
            guard let read = AssistantSchedulePlace(name: placeName, latitude: latitude, longitude: longitude) else { return false }
            place = read
        }
        if let plannedSpend, !(plannedSpend.isFinite && plannedSpend > 0 && plannedSpend <= Self.maximumPlannedSpend) { return false }
        if let clearPlace, !(allowsClear && clearPlace && place == nil) { return false }
        self.place = place
        self.plannedSpend = plannedSpend
        self.clearPlace = clearPlace == true
        return true
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
