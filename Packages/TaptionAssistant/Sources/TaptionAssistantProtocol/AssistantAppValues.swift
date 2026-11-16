import Foundation
import TaptionLedgerCore

// 명령이 담는 앱 값 타입(RMN1114A25). 이름·저장 값(rawValue)만 여기 있고, 문구·저장 키·앱 모델로 읽고 쓰는 길은 앱의 extension에 있다.

/// 여행 일정 상태(TRP1110A09). 없거나 모르는 값은 계획이고, 계획은 저장하지 않아 예전 기록 바이트를 지킨다.
public enum TripItemStatus: String, CaseIterable, Identifiable, Hashable, Sendable {
    case booked, planned, tentative

    public var id: String { rawValue }

    public init(raw: String?) {
        // 갔음·건너뜀 확정은 `visited/booked`처럼 앞에 붙는다(TVZ1116C01). 뒤의 원래 상태만 읽는다.
        let raw = raw?.split(separator: "/").last.map(String.init)
        self = raw.flatMap { Self(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .planned
    }

    /// 알아볼 수 있게 적힌 값만 읽는다. 없거나 모르는 값은 nil(REV1110A06).
    public init?(explicit raw: String?) {
        guard let raw, let value = Self(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        self = value
    }

    /// 저장 값. 계획은 nil.
    public var stored: String? { self == .planned ? nil : rawValue }
}

/// AI가 켜고 끌 수 있는 표시 설정(AIR1110A03). 이 값들만 받는다.
public enum AssistantDisplayOption: String, CaseIterable, Codable, Sendable {
    case mapPhotos
    case mapRoutes
    case mapFootprints
    /// ACT1114A07: 시간 사이드바, 탈것 모습.
    case sidebar
    case vehicles
}

/// AI가 열어 달라고 할 수 있는 화면(ACX1112A01). 자료를 바꾸는 화면 동작은 없다.
public enum AssistantScreen: String, CaseIterable, Codable, Sendable {
    case paymentAutomation, shortcuts, aiConnection, ledger, dataProtection, settings
    // ACC1112A01
    case salary, carAudio, alarm, placeBook, passport, unconfirmedReview, travel
    // ACT1114A07
    case dayCard, calendarConnect, categoryAdd, paymentAlerts, aiRules
}

/// AI가 바꿀 수 있는 기기 설정(ACB1112A01). 이 이름만 받고, 값은 형과 범위를 본 뒤 정해진 글자 꼴로 다룬다.
/// 급여 금액도 읽기·바꾸기 모두 된다(대표 결정 2026-11-12, PAY1112A01).
public enum AssistantSetting: String, CaseIterable, Codable, Sendable {
    case tollVehicle, salaryMode, annualPay, monthlyPay, payIsNet, showsNetPay, hourlyPay, hourlyPayIsNet, hourlyTax, weeklyHolidayPay
    /// ACC1112A01: 앱 자료에 있는 설정. 화면의 설정 함수로 바꾼다. 알림은 끄기만 받는다(켜기는 iOS 권한 창이 필요하다).
    case reduceMotion, weather, weatherSidebar, gpsIntervalSeconds, cat, notifications
    /// ACT1114A07: 지도에 보일 메모(지도 화면 `@AppStorage`와 같은 키).
    case memoDisplay
    /// ACT1114A09: 보폭(cm, 보폭 보정 화면과 같은 키), Watch 수집 단계, 위치 수집·사진은 끄기만(켜기는 iOS 권한 창이 필요하다).
    case strideCentimeters, watchAcceleration, watchDataSync, location, photos

    public static let tripTitleLimit = 60
    /// Watch 수집 단계 이름. 차례가 `TaptionWatchAccelerationProfile`·`TaptionWatchDataSyncProfile`의 값이다.
    public static let watchProfiles = ["off", "batterySaver", "balanced", "accuracy"]

    /// 급여 쪽 설정. 연봉 카운터의 「AI 연동」을 끄면 올리지도 바꾸지도 않는다(PAY1112A02).
    public var isSalary: Bool {
        switch self {
        case .salaryMode, .annualPay, .monthlyPay, .payIsNet, .showsNetPay, .hourlyPay, .hourlyPayIsNet, .hourlyTax, .weeklyHolidayPay: true
        default: false
        }
    }

    /// 앱 자료(`snapshot.settings`)에 있어 모델의 설정 함수로 바꾸는 것.
    public var isModelBacked: Bool {
        switch self {
        case .reduceMotion, .weather, .weatherSidebar, .gpsIntervalSeconds, .cat, .notifications: true
        case .watchAcceleration, .watchDataSync, .location, .photos: true
        default: false
        }
    }
}

/// 말풍선 종류(BUB1110A02). 앱에서는 `AssistantBubble.Kind`로 부른다.
public enum AssistantBubbleKind: String, Codable, Sendable {
    case routine
    case event
}

/// AI가 고치는 가계부 칸(AIQ1111A01). nil인 칸은 그대로 둔다.
public struct AssistantExpenseChange: Equatable, Sendable {
    public var delete = false
    public var amount: Double?
    public var currency: String?
    public var title: String?
    public var category: LedgerCategory?
    public var kind: LedgerEntry.Kind?
    /// ACT1114A07: 여행 장부(빈 글이면 일상으로), 몫을 나누는 사람(비면 다 같이), 메모, 새 날짜(`YYYY-MM-DD`)와 시각(자정부터의 분).
    public var tripID: String?
    public var shareNames: [String]?
    public var note: String?
    public var date: String?
    public var minutes: Int?

    public init(
        delete: Bool = false, amount: Double? = nil, currency: String? = nil, title: String? = nil, category: LedgerCategory? = nil,
        kind: LedgerEntry.Kind? = nil, tripID: String? = nil, shareNames: [String]? = nil, note: String? = nil, date: String? = nil, minutes: Int? = nil
    ) {
        self.delete = delete
        self.amount = amount
        self.currency = currency
        self.title = title
        self.category = category
        self.kind = kind
        self.tripID = tripID
        self.shareNames = shareNames
        self.note = note
        self.date = date
        self.minutes = minutes
    }

    public var touchesTrip: Bool { tripID != nil || shareNames != nil }

    public func applied(to entry: LedgerEntry, calendar: Calendar = .autoupdatingCurrent) -> LedgerEntry {
        var value = entry
        if let amount { value.amount = amount }
        if let currency { value.currency = currency }
        if let title { value.title = title }
        if let category { value.category = category }
        if let kind { value.kind = kind }
        if let tripID {
            value.tripID = tripID.isEmpty ? nil : tripID
            if tripID.isEmpty { value.shareNames = nil }
        }
        if let shareNames { value.shareNames = shareNames.isEmpty ? nil : shareNames }
        if let note { value.note = note }
        value.occurredAt = AssistantWhenChange(date: date, minutes: minutes).applied(to: entry.occurredAt, calendar: calendar)
        return value
    }

    /// 몫을 나누는 사람 이름: 1~30자, 20명까지, 서로 다름. 틀리면 nil.
    public static func sharers(_ names: [String], minimum: Int) -> [String]? {
        let cleaned = names.compactMap { AssistantCommandParser.clean($0, max: 30) }
        return cleaned.count == names.count && (minimum...20).contains(names.count) && Set(cleaned).count == cleaned.count ? cleaned : nil
    }
}
