import Foundation
import TaptionPlanCore

enum CategoryIcon: String, Codable, CaseIterable, Sendable {
    case briefcase
    case building
    case book
    case graduation
    case target
    case award
    case stroller
    case family
    case shield
    case health
    case exercise
    case sleep
    case performance
    case music
    case travel
    case location
    case photo
    case home
    case meal
    case cafe
    case pet
    case shopping
    case nature
    case calendar
    case event
    case memo
    case movement
    case activity
    case relationship
    case work
    case community
    case student
    case exam
    case military
    case athlete
    case pregnancy
    case caregiver
    case government
    case food
}

struct CategoryDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var icon: CategoryIcon
    var lightHex: String
    var darkHex: String
    var actualHex: String
    var sortOrder: Int
    var isHidden: Bool
    var isBuiltIn: Bool

    init(
        id: String,
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        darkHex: String,
        actualHex: String,
        sortOrder: Int,
        isHidden: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.lightHex = lightHex
        self.darkHex = darkHex
        self.actualHex = actualHex
        self.sortOrder = sortOrder
        self.isHidden = isHidden
        self.isBuiltIn = isBuiltIn
    }
}

struct CalendarRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var calendarID: String
    var title: String
    var span: TimeSpan
    var isAllDay: Bool
    var calendarTitle: String
    var calendarColorHex: String?
    var sourceTitle: String?
    var sourceIdentifier: String? = nil
    /// EventKit keeps the event's wall-clock zone and floating-time state
    /// separately from its absolute Date values. Keep both so a day reload or
    /// device-zone change does not move an all-day/floating event to another
    /// day.
    var timeZoneIdentifier: String? = nil
    var isFloatingTime: Bool? = nil
    var originalStartDateComponents: DateComponents? = nil
    var originalEndDateComponents: DateComponents? = nil
    var externalIdentifier: String? = nil
    var recurrenceIdentifier: String? = nil
    /// 반복 일정의 원래 발생 시각. 특정 발생분이 다른 날로 이동해도
    /// 이전 기록과 같은 occurrence로 교체할 수 있게 보존한다.
    var occurrenceDate: Date? = nil
    /// 일정 메모. 구글은 HTML로 줄 수 있어 `CalendarNotesText.plain`으로 푼 글자를 담는다.
    var notes: String? = nil
    /// 정지 구간 문맥 추론에서 쓰는 EventKit 부가 정보. 이전 보관본은 값이
    /// 없으므로 옵셔널로 둔다.
    var attendeeCount: Int? = nil
    var isCancelled: Bool? = nil

    /// The timeline uses the device calendar for day buckets and labels. A
    /// floating or all-day event is date-based, so rebuild its span from the
    /// original wall-clock components instead of interpreting EventKit's Date
    /// as an instant in the current zone.
    func normalizedForDisplay(
        in calendar: Calendar = .autoupdatingCurrent
    ) -> CalendarRecord {
        guard (isAllDay || isFloatingTime == true),
              let originalStartDateComponents,
              let start = Self.date(
                  from: originalStartDateComponents,
                  in: calendar,
                  allDay: isAllDay
              ) else {
            return self
        }
        let end = originalEndDateComponents.flatMap {
            Self.date(from: $0, in: calendar, allDay: isAllDay)
        } ?? calendar.date(byAdding: .day, value: 1, to: start)
        guard let end, end > start else { return self }
        var value = self
        value.span = TimeSpan(start: start, end: end)
        return value
    }

    private static func date(
        from components: DateComponents,
        in calendar: Calendar,
        allDay: Bool
    ) -> Date? {
        var value = DateComponents()
        value.era = components.era
        value.year = components.year
        value.month = components.month
        value.day = components.day
        if !allDay {
            value.hour = components.hour
            value.minute = components.minute
            value.second = components.second
            value.nanosecond = components.nanosecond
        }
        return calendar.date(from: value)
    }
}

struct PhotoMoment: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var capturedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var isFavorite: Bool
    var isHiddenFromTimeline: Bool
    var location: GeoPoint?
    var linkedPlanID: UUID?
    var linkedPlaceID: UUID?
    /// 스크린샷 여부. 예전 기록에는 없으므로 Optional.
    var isScreenshot: Bool?
    /// 사진에 위치가 없어 같은 시각의 내 이동 기록에서 추정한 위치인지.
    var isLocationEstimated: Bool?

    init(
        id: String,
        capturedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        isHiddenFromTimeline: Bool,
        location: GeoPoint? = nil,
        linkedPlanID: UUID? = nil,
        linkedPlaceID: UUID? = nil,
        isScreenshot: Bool? = nil,
        isLocationEstimated: Bool? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isHiddenFromTimeline = isHiddenFromTimeline
        self.location = location
        self.linkedPlanID = linkedPlanID
        self.linkedPlaceID = linkedPlaceID
        self.isScreenshot = isScreenshot
        self.isLocationEstimated = isLocationEstimated
    }
}

struct PhotoCluster: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var representative: PhotoMoment
    var photos: [PhotoMoment]

    var capturedAt: Date { representative.capturedAt }
    var additionalCount: Int { max(0, photos.count - 1) }
}

extension CalendarRecord {
    /// 구글 로그인으로 직접 읽은 일정. 기기 캘린더 권한과 따로 관리한다.
    static let googleAccountCalendarID = "google-primary"
    var isGoogleAccountEvent: Bool { calendarID == Self.googleAccountCalendarID }
}

extension CalendarRecord {
    private static let meetingWords = ["회의", "미팅", "meeting", "스크럼", "scrum", "sync"]
    private static let mealWords = ["아침", "점심", "저녁", "식사", "lunch", "dinner", "breakfast"]

    /// 시간이 정해진 회의 일정인가. 제목이나 참석자 수로만 본다.
    var isMeetingLike: Bool {
        guard !isAllDay, isCancelled != true else { return false }
        let text = title.lowercased()
        if Self.mealWords.contains(where: text.contains) { return false }
        return Self.meetingWords.contains(where: text.contains) || (attendeeCount ?? 0) >= 2
    }
}
