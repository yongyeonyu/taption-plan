import Foundation
import TaptionPlanCore

/// AI가 켜고 끌 수 있는 표시 설정(AIR1110A03). 이 셋만 받는다.
enum AssistantDisplayOption: String, CaseIterable, Codable, Sendable {
    case mapPhotos
    case mapRoutes
    case mapFootprints

    /// 지도 화면 `@AppStorage`와 같은 키.
    var defaultsKey: String {
        switch self {
        case .mapPhotos: "mapHomeShowsPhotos"
        case .mapRoutes: "mapHomeShowsRoutes"
        case .mapFootprints: "mapHomeShowsFootprints"
        }
    }
}

/// 새 명령 읽기(AIR1110A03). 서버와 같은 칸 이름을 쓰고, 위험한 일(전체 삭제·백업·키·PIN·권한·공유 수준·결제)은 받지 않는다.
extension AssistantCommandParser {
    static func dataAction(_ raw: Raw, day: Date?, calendar: Calendar) -> AssistantCommand.Action? {
        switch raw.action {
        case "addGoal":
            guard let title = clean(raw.title, max: 200), let start = (raw.start ?? raw.date).flatMap({ self.day($0, calendar: calendar) })
            else { return nil }
            var end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            if let text = raw.end {
                guard let value = self.day(text, calendar: calendar), value >= start else { return nil }
                end = value
            }
            return .addGoal(title: title, start: start, end: end, categoryID: clean(raw.categoryId, max: 100))
        case "updateGoal":
            guard let goalID = clean(raw.goalId ?? raw.planId, max: 100) else { return nil }
            if raw.title != nil, clean(raw.title, max: 200) == nil { return nil }
            if raw.categoryId != nil, clean(raw.categoryId, max: 100) == nil { return nil }
            let start = raw.start.map { self.day($0, calendar: calendar) }, end = raw.end.map { self.day($0, calendar: calendar) }
            guard start.map({ $0 != nil }) ?? true, end.map({ $0 != nil }) ?? true else { return nil }
            if let from = start ?? nil, let to = end ?? nil, to < from { return nil }
            let title = clean(raw.title, max: 200), categoryID = clean(raw.categoryId, max: 100)
            guard title != nil || start != nil || end != nil || categoryID != nil else { return nil }
            return .updateGoal(goalID: goalID, title: title, start: start ?? nil, end: end ?? nil, categoryID: categoryID)
        case "deleteGoal":
            return clean(raw.goalId ?? raw.planId, max: 100).map { .deleteGoal(goalID: $0) }
        case "addTripStop":
            guard let title = clean(raw.title, max: 200), let day else { return nil }
            let status = tripStatus(raw.status), place = coordinate(raw)
            guard status.ok, place.ok else { return nil }
            if raw.tripId != nil, clean(raw.tripId, max: 100) == nil { return nil }
            return .addTripStop(title: title, day: day, coordinate: place.value, status: status.value, tripID: clean(raw.tripId, max: 100))
        case "updateTripStop":
            guard let stopID = clean(raw.stopId, max: 100) else { return nil }
            if raw.title != nil, clean(raw.title, max: 200) == nil { return nil }
            if raw.date != nil, day == nil { return nil }
            if let order = raw.order, !(0...999).contains(order) { return nil }
            let status = tripStatus(raw.status)
            guard status.ok else { return nil }
            let title = clean(raw.title, max: 200)
            guard title != nil || day != nil || raw.order != nil || status.value != nil else { return nil }
            return .updateTripStop(stopID: stopID, title: title, day: day, order: raw.order, status: status.value)
        case "deleteTripStop":
            return clean(raw.stopId, max: 100).map { .deleteTripStop(stopID: $0) }
        case "setTripItemStatus":
            guard let tripID = clean(raw.tripId, max: 100), let itemID = clean(raw.itemId, max: 100),
                  let status = tripStatus(raw.status).value else { return nil }
            return .setTripItemStatus(tripID: tripID, itemID: itemID, status: status)
        case "updateSleep":
            guard let recordID = clean(raw.recordId, max: 100) else { return nil }
            let start = raw.start.map(AssistantScheduleTime.init(text:)), end = raw.end.map(AssistantScheduleTime.init(text:))
            guard start != nil || end != nil, start.map({ $0 != nil }) ?? true, end.map({ $0 != nil }) ?? true else { return nil }
            return .updateSleep(recordID: recordID, start: start ?? nil, end: end ?? nil)
        case "setBubble":
            // BUB1110A02: routine(기본)은 시간대가 있어야 하고, event는 시간대가 없으면 그날 하루 전체다.
            guard let day, let kind = AssistantBubble.Kind(rawValue: raw.kind ?? AssistantBubble.Kind.routine.rawValue),
                  let text = raw.text.flatMap(AssistantBubbleText.cleaned), AssistantBubbleText(text) != nil else { return nil }
            if raw.start == nil, raw.end == nil, kind == .event,
               let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) {
                return .setBubble(start: calendar.startOfDay(for: day), end: next, text: text, kind: kind)
            }
            guard let start = raw.start.flatMap({ clock($0, on: day, calendar: calendar) }),
                  let end = raw.end.flatMap({ clock($0, on: day, calendar: calendar) }), end > start else { return nil }
            return .setBubble(start: start, end: end, text: text, kind: kind)
        case "addExpense":
            return expense(raw, calendar: calendar)
        case "updateExpense":
            return expenseChange(raw)
        case "addPaymentRule":
            return LedgerMessageRules.rule(name: raw.name, pattern: raw.pattern, sample: raw.sample, kind: raw.kind).map { .addPaymentRule($0) }
        case "classifyUnconfirmed":
            guard let day, let categoryID = clean(raw.categoryId, max: 100),
                  let start = raw.start.flatMap({ clock($0, on: day, calendar: calendar) }),
                  let end = raw.end.flatMap({ clock($0, on: day, calendar: calendar) }), end > start else { return nil }
            if raw.title != nil, clean(raw.title, max: 100) == nil { return nil }
            return .classifyUnconfirmed(start: start, end: end, title: clean(raw.title, max: 100), categoryID: categoryID)
        case "setTravelMode":
            guard day != nil, let moveID = raw.moveId.flatMap(UUID.init(uuidString:)), let mode = raw.mode.flatMap(travelMode) else { return nil }
            return .setTravelMode(moveID: moveID, mode: mode)
        default:
            return settingAction(raw)
        }
    }

    /// 하루 기록의 수단 이름(`AssistantActivityBuilder.mode`)을 앱 수단으로. 「other」는 받지 않는다.
    static func travelMode(_ name: String) -> TravelMode? {
        switch name {
        case "walk": .walking
        case "subway": .subway
        case "bus": .bus
        case "car": .car
        case "train": .train
        case "flight": .airplane
        default: nil
        }
    }

    private static func settingAction(_ raw: Raw) -> AssistantCommand.Action? {
        switch raw.action {
        case "setLanguage":
            return raw.language.flatMap(language).map { .setLanguage($0) }
        case "setMapStyle":
            return raw.mapStyle.flatMap { MapDisplayStyle(rawValue: $0) }.map { .setMapStyle($0) }
        case "setTheme":
            // 테마는 지도 스타일을 따라가므로 같은 색의 지도로 바꾼다.
            return raw.theme.flatMap(themeStyle).map { .setMapStyle($0) }
        case "setDisplayOption":
            guard let option = raw.option.flatMap(AssistantDisplayOption.init(rawValue:)), let enabled = raw.enabled else { return nil }
            return .setDisplayOption(option, enabled: enabled)
        default:
            return nil
        }
    }

    /// 좌표는 둘 다 없거나(이름으로 찾는다) 둘 다 범위 안이어야 한다. 서버와 같은 규칙이다.
    private static func coordinate(_ raw: Raw) -> (ok: Bool, value: AssistantCoordinate?) {
        let latitude = raw.latitude ?? raw.lat, longitude = raw.longitude ?? raw.lng
        if latitude == nil, longitude == nil { return (true, nil) }
        guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return (false, nil) }
        return (true, AssistantCoordinate(latitude: latitude, longitude: longitude))
    }

    /// 없으면 바꾸지 않고(`value` nil), 모르는 값이면 틀린 명령(`ok` false)이다.
    private static func tripStatus(_ text: String?) -> (ok: Bool, value: TripItemStatus?) {
        guard let text else { return (true, nil) }
        let status = TripItemStatus(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased())
        return (status != nil, status)
    }

    static func language(_ code: String) -> AppLanguagePreference? {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "auto", "automatic", "system": .automatic
        case "ko", "korean": .korean
        case "en", "english": .english
        case let value: AppLanguagePreference(rawValue: value).flatMap { $0 == .automatic || $0 == .korean || $0 == .english ? nil : $0 }
        }
    }

    /// 서버가 받는 테마 이름과 그 색의 지도. 연결 안내도 이 목록으로 만든다.
    static let themes: [(name: String, style: MapDisplayStyle)] = [
        ("classic", .standard), ("navy", .mapLibreNight), ("purple", .mapLibreCasual), ("brown", .mapLibreContrast), ("ink", .mapLibreInk),
    ]

    static func themeStyle(_ theme: String) -> MapDisplayStyle? { themes.first { $0.name == theme }?.style }
}

/// 여행 핀·일정 목록 한 벌(되돌리기용).
extension AssistantCommandParser {
    /// 가계부 기록(LED1110A01). 서버와 같은 규칙: 금액 0~10¹⁰, 통화 세 글자, 제목 1~60자, 분류는 정해진 것만.
    static func expense(_ raw: Raw, now: Date = .now, calendar: Calendar) -> AssistantCommand.Action? {
        guard let amount = raw.amount, amount.isFinite, amount > 0, amount <= 1e10,
              let title = clean(raw.title, max: 60),
              let at = memoInstant(date: raw.date, time: raw.time, now: now, calendar: calendar) else { return nil }
        let currency = (raw.currency ?? "KRW").uppercased()
        guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var category = LedgerCategory.guess(title)
        if let name = raw.category {
            guard let value = LedgerCategory(rawValue: name) else { return nil }
            category = value
        }
        var kind = LedgerEntry.Kind.expense
        if let name = raw.kind {
            guard let value = LedgerEntry.Kind(rawValue: name) else { return nil }
            kind = value
        }
        if raw.payer != nil, clean(raw.payer, max: 30) == nil { return nil }
        return .addExpense(LedgerEntry(
            occurredAt: at, amount: amount, currency: currency, kind: kind, category: category,
            title: title, payer: clean(raw.payer, max: 30), note: clean(raw.note, max: 200), source: .assistant
        ))
    }

    /// updateExpense(AIQ1111A01): 고칠 칸이 하나라도 있거나 지우기여야 한다. 서버와 같은 규칙.
    static func expenseChange(_ raw: Raw) -> AssistantCommand.Action? {
        guard let id = raw.entryId.flatMap(UUID.init(uuidString:)) else { return nil }
        var change = AssistantExpenseChange(delete: raw.delete == true)
        if let amount = raw.amount {
            guard amount.isFinite, amount > 0, amount <= 1e10 else { return nil }
            change.amount = amount
        }
        if let currency = raw.currency?.uppercased() {
            guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            change.currency = currency
        }
        if raw.title != nil {
            guard let title = clean(raw.title, max: 60) else { return nil }
            change.title = title
        }
        if let name = raw.category {
            guard let value = LedgerCategory(rawValue: name) else { return nil }
            change.category = value
        }
        if let name = raw.kind {
            guard let value = LedgerEntry.Kind(rawValue: name) else { return nil }
            change.kind = value
        }
        guard change.delete || change != AssistantExpenseChange() else { return nil }
        return .updateExpense(entryID: id, change: change)
    }
}

/// AI가 고치는 가계부 칸(AIQ1111A01). nil인 칸은 그대로 둔다.
struct AssistantExpenseChange: Equatable, Sendable {
    var delete = false
    var amount: Double?
    var currency: String?
    var title: String?
    var category: LedgerCategory?
    var kind: LedgerEntry.Kind?

    func applied(to entry: LedgerEntry) -> LedgerEntry {
        var value = entry
        if let amount { value.amount = amount }
        if let currency { value.currency = currency }
        if let title { value.title = title }
        if let category { value.category = category }
        if let kind { value.kind = kind }
        return value
    }
}

struct AssistantTravelState: Codable, Equatable, Sendable {
    var stops: [TravelPlanStop]
    var items: [TravelTripItem]?

    init(_ settings: AppFeatureSettings) {
        stops = settings.travelPlanStops
        items = settings.travelTripItems
    }

    /// 되살린 계획이 새 id를 받았으면 그 id로 잇는다.
    func apply(to settings: inout AppFeatureSettings, renamed: [UUID: UUID]) {
        settings.travelPlanStops = stops.map { stop in
            var copy = stop
            if let planID = stop.planID, let renamedID = renamed[planID] { copy.planID = renamedID }
            return copy
        }
        settings.travelTripItems = items?.map { item in
            var copy = item
            if let planID = item.planID, let renamedID = renamed[planID] { copy.planID = renamedID }
            return copy
        }
    }
}

struct AssistantTravelChange: Codable, Equatable, Sendable {
    var before: AssistantTravelState
    var after: AssistantTravelState
}

/// 설정 하나의 전·후 글자 값. 지도 스타일은 앱 자료에, 나머지는 기기 설정에 있다.
struct AssistantPreferenceChange: Codable, Equatable, Sendable {
    static let mapStyleKey = "settings.mapDisplayStyle"
    static let languageKey = "language"

    var key: String
    var before: String?
    var after: String?
}

/// 기기 설정 읽고 쓰기. 시험은 따로 만든 저장소를 쓰고 앱 전체 언어를 건드리지 않는다.
@MainActor
struct AssistantPreferenceStore {
    var defaults: UserDefaults
    var isLive: Bool
    var bubbleFile = AssistantBubbleStore.url
    var ledger = LedgerBook.shared

    static var live: Self { Self(defaults: .standard, isLive: true) }

    /// 시험마다 따로 둔 말풍선 파일을 쓴다.
    static func test(_ defaults: UserDefaults) -> Self {
        let name = defaults.string(forKey: "assistantBubbleTestFile") ?? UUID().uuidString
        defaults.set(name, forKey: "assistantBubbleTestFile")
        return Self(
            defaults: defaults, isLive: false, bubbleFile: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json"),
            ledger: LedgerBook(store: { nil })
        )
    }

    func value(_ key: String) -> String? {
        if key == AssistantPreferenceChange.languageKey {
            return isLive ? AppLanguagePreference.current.rawValue : AppLanguagePreference.load(from: defaults).rawValue
        }
        guard let option = AssistantDisplayOption.allCases.first(where: { $0.defaultsKey == key }) else { return nil }
        return String(defaults.object(forKey: option.defaultsKey) as? Bool ?? true)
    }

    func set(_ key: String, value: String?, model: AppModel?) {
        if key == AssistantPreferenceChange.languageKey {
            let preference = value.flatMap(AppLanguagePreference.init(rawValue:)) ?? .automatic
            AppLanguagePreference.save(preference, to: isLive ? nil : defaults)
            if isLive { model?.languagePreferenceDidChange() }
            return
        }
        guard AssistantDisplayOption.allCases.contains(where: { $0.defaultsKey == key }) else { return }
        defaults.set(value == "true", forKey: key)
    }
}
