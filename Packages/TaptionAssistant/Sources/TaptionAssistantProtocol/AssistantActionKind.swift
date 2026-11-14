import Foundation

/// AI 비서 명령 종류. 「AI 비서」 메뉴에서 하나씩 끌 수 있고 기본은 모두 켠다(AIR1110A02).
/// 등록부 동작(ACT1114A07)은 `.operation(이름)` 하나로 받는다. 저장 값(토글 키·로그·올리는 목록)은 예전처럼 동작 이름 글자다.
/// 제목 문구는 앱의 extension에 있다.
public enum AssistantActionKind: Hashable, CaseIterable, Identifiable, Codable, Sendable, RawRepresentable {
    case addMemo, addSchedule, updateActivity
    case hideRecord, mergeRecords, updateRecordTime
    case updateSchedule, deleteSchedule, updateMemo, deleteMemo
    // AIR1110A03
    case addGoal, updateGoal, deleteGoal
    case addTripStop, updateTripStop, deleteTripStop, setTripItemStatus
    case updateSleep, setLanguage, setMapStyle, setDisplayOption, setBubble
    case addExpense
    // AIQ1111A01: 앱이 넣은 결제 문자 기록을 AI가 다듬는다.
    case updateExpense
    // ACT1111A01
    case classifyUnconfirmed, setTravelMode
    // PRL1112A01
    case addPaymentRule
    // ACX1112A01
    case setBudget, addOwnAccount, removeOwnAccount, deletePaymentRule, resolveReview, deleteInboxItem, openScreen
    // ASK1112A01
    case askUser
    // ACA1112A01
    case addPlace, updatePlace, deletePlace, addCategory, updateCategory
    // ACB1112A01
    case addTrip, updateTrip, deleteTrip, setSetting
    // ACD1112A01
    case requestApproval
    // HND1112A01
    case resolvePlaceSuggestion, setCarAudio, setCalendarTitleDetail
    // TBG1112A01
    case setTripBudget
    /// ACT1114A07: `AssistantOperations`에 등록한 동작. 이름이 토글 id다.
    case operation(String)

    /// 등록부 이전의 49개. 새 동작은 여기가 아니라 `AssistantOperations`의 묶음 배열에 더한다.
    public static let builtIn: [Self] = [
        .addMemo, .addSchedule, .updateActivity, .hideRecord, .mergeRecords, .updateRecordTime, .updateSchedule, .deleteSchedule, .updateMemo, .deleteMemo,
        .addGoal, .updateGoal, .deleteGoal, .addTripStop, .updateTripStop, .deleteTripStop, .setTripItemStatus,
        .updateSleep, .setLanguage, .setMapStyle, .setDisplayOption, .setBubble, .addExpense, .updateExpense, .classifyUnconfirmed, .setTravelMode,
        .addPaymentRule, .setBudget, .addOwnAccount, .removeOwnAccount, .deletePaymentRule, .resolveReview, .deleteInboxItem, .openScreen, .askUser,
        .addPlace, .updatePlace, .deletePlace, .addCategory, .updateCategory, .addTrip, .updateTrip, .deleteTrip, .setSetting, .requestApproval,
        .resolvePlaceSuggestion, .setCarAudio, .setCalendarTitleDetail, .setTripBudget,
    ]
    private static let builtInByName = Dictionary(builtIn.map { ($0.rawValue, $0) }, uniquingKeysWith: { first, _ in first })

    public static var allCases: [Self] { builtIn + AssistantOperations.all.map { .operation($0.spec.name) } }

    /// 예전 49개는 case 이름, 등록부 동작은 그 이름.
    public var rawValue: String {
        if case let .operation(name) = self { return name }
        return String(describing: self)
    }

    /// 아는 동작만 받는다(명령 읽기용).
    public init?(rawValue: String) {
        if let known = Self.builtInByName[rawValue] { self = known }
        else if AssistantOperations.spec(rawValue) != nil { self = .operation(rawValue) }
        else { return nil }
    }

    /// 로그는 모르는 이름도 읽는다(동작이 빠진 빌드에서도 「AI가 한 일」 파일을 잃지 않게).
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = Self.builtInByName[name] ?? .operation(name)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }

    public var id: String { rawValue }
}

/// 종류별 켜기·끄기. 값이 없으면 켠 것으로 본다(AIR1110A02). `startsOff`인 등록부 동작만 값이 없으면 끈 것으로 본다(ACT1114A09).
public enum AssistantActionToggles {
    public static func key(_ kind: AssistantActionKind) -> String { "assistantAction.\(kind.rawValue)" }

    public static func isEnabled(_ kind: AssistantActionKind, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(kind)) as? Bool ?? !(AssistantOperations.spec(kind.rawValue)?.startsOff ?? false)
    }

    public static func set(_ kind: AssistantActionKind, enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(kind))
    }
}
