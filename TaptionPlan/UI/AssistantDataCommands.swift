import Foundation
import Observation
import TaptionPlanCore

/// AI가 켜고 끌 수 있는 표시 설정(AIR1110A03). 이 셋만 받는다.
enum AssistantDisplayOption: String, CaseIterable, Codable, Sendable {
    case mapPhotos
    case mapRoutes
    case mapFootprints
    /// ACT1114A07: 시간 사이드바, 탈것 모습.
    case sidebar
    case vehicles

    /// 지도 화면 `@AppStorage`와 같은 키.
    var defaultsKey: String {
        switch self {
        case .mapPhotos: "mapHomeShowsPhotos"
        case .mapRoutes: "mapHomeShowsRoutes"
        case .mapFootprints: "mapHomeShowsFootprints"
        case .sidebar: "mapHomeSidebarVisible"
        case .vehicles: MapHomeStickmanAction.vehicleDisplayKey
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
            return expenseChange(raw, calendar: calendar)
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
            if raw.line != nil, clean(raw.line, max: 20) == nil { return nil }
            return .setTravelMode(moveID: moveID, mode: mode, line: clean(raw.line, max: 20))
        default:
            return settingAction(raw) ?? appAction(raw, calendar: calendar)
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
        // ACT1114A07: 화면에서 고를 수 있는 나머지 수단.
        case "run": .running
        case "cycling": .cycling
        case "taxi": .taxi
        case "ship": .ship
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

    /// 가계부 설정·정리와 화면 열기(ACX1112A01). 서버와 같은 규칙으로 다시 본다.
    static func appAction(_ raw: Raw, now: Date = .now, calendar: Calendar) -> AssistantCommand.Action? {
        switch raw.action {
        case "setBudget":
            guard let amount = raw.amountKRW, amount.isFinite, (0...LedgerBudget.assistantLimitKRW).contains(amount) else { return nil }
            guard let text = raw.month else { return .setBudget(month: LedgerBook.monthKey(now, calendar: calendar), amountKRW: amount.rounded()) }
            return month(text).map { .setBudget(month: $0, amountKRW: amount.rounded()) }
        case "addOwnAccount":
            return LedgerOwnAccounts.commandName(raw.name).map { .addOwnAccount($0) }
        case "removeOwnAccount":
            return LedgerOwnAccounts.commandName(raw.name).map { .removeOwnAccount($0) }
        case "deletePaymentRule":
            return raw.ruleId.flatMap(UUID.init(uuidString:)).map { .deletePaymentRule($0) }
        case "resolveReview":
            guard let id = raw.reviewId.flatMap(UUID.init(uuidString:)), raw.decision == "add" || raw.decision == "discard" else { return nil }
            return .resolveReview(id, add: raw.decision == "add")
        case "deleteInboxItem":
            return raw.inboxId.flatMap(UUID.init(uuidString:)).map { .deleteInboxItem($0) }
        case "openScreen":
            return raw.screen.flatMap(AssistantScreen.init(rawValue:)).map { .openScreen($0) }
        case "addPlace":
            let place = coordinate(raw)
            guard let name = clean(raw.name, max: AssistantCatalogLimits.placeName), place.ok, AssistantCatalogLimits.radiusOK(raw.radius) else { return nil }
            return .addPlace(name: name, coordinate: place.value, radius: raw.radius, autoRecord: raw.autoRecord)
        case "updatePlace":
            let place = coordinate(raw)
            guard let id = raw.placeId.flatMap(UUID.init(uuidString:)), place.ok, AssistantCatalogLimits.radiusOK(raw.radius) else { return nil }
            if raw.name != nil, clean(raw.name, max: AssistantCatalogLimits.placeName) == nil { return nil }
            guard raw.name != nil || place.value != nil || raw.radius != nil || raw.autoRecord != nil else { return nil }
            return .updatePlace(placeID: id, name: clean(raw.name, max: AssistantCatalogLimits.placeName), coordinate: place.value, radius: raw.radius, autoRecord: raw.autoRecord)
        case "deletePlace":
            return raw.placeId.flatMap(UUID.init(uuidString:)).map { .deletePlace($0) }
        case "addCategory":
            guard let name = clean(raw.name, max: AssistantCatalogLimits.categoryName), let color = raw.color, AssistantCatalogLimits.isColor(color) else { return nil }
            if raw.icon != nil, raw.icon.flatMap(CategoryIcon.init(rawValue:)) == nil { return nil }
            return .addCategory(name: name, color: color.uppercased(), icon: raw.icon.flatMap(CategoryIcon.init(rawValue:)))
        case "updateCategory":
            guard let id = clean(raw.categoryId, max: 100) else { return nil }
            if raw.name != nil, clean(raw.name, max: AssistantCatalogLimits.categoryName) == nil { return nil }
            if let color = raw.color, !AssistantCatalogLimits.isColor(color) { return nil }
            if raw.icon != nil, raw.icon.flatMap(CategoryIcon.init(rawValue:)) == nil { return nil }
            guard raw.name != nil || raw.color != nil || raw.icon != nil || raw.hidden != nil else { return nil }
            return .updateCategory(
                categoryID: id, name: clean(raw.name, max: AssistantCatalogLimits.categoryName), color: raw.color?.uppercased(),
                icon: raw.icon.flatMap(CategoryIcon.init(rawValue:)), hidden: raw.hidden
            )
        case "addTrip":
            guard let title = clean(raw.title, max: AssistantSetting.tripTitleLimit) else { return nil }
            if let code = raw.countryCode, code.range(of: "^[A-Z]{2}$", options: .regularExpression) == nil { return nil }
            if raw.regionName != nil, clean(raw.regionName, max: 40) == nil { return nil }
            if let currency = raw.currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil { return nil }
            var trip = TravelTrip(id: "trip-\(UUID().uuidString.lowercased())", title: title, startDay: "", endDay: "", countryCode: raw.countryCode,
                                  regionName: clean(raw.regionName, max: 40), currencyCode: raw.currency)
            if let days = raw.wishDays {
                guard (1...60).contains(days), raw.start == nil, raw.end == nil else { return nil }
                trip.wishDays = days
            } else {
                guard let start = raw.start, TravelTripDay.components(start) != nil else { return nil }
                let end = raw.end ?? start
                guard let length = TravelTripDay.days(from: start, to: end), length >= 0 else { return nil }
                trip.startDay = start
                trip.endDay = end
            }
            return .addTrip(trip)
        case "updateTrip":
            guard let id = clean(raw.tripId, max: 100) else { return nil }
            if raw.title != nil, clean(raw.title, max: AssistantSetting.tripTitleLimit) == nil { return nil }
            for day in [raw.start, raw.end].compactMap({ $0 }) where TravelTripDay.components(day) == nil { return nil }
            if let start = raw.start, let end = raw.end, (TravelTripDay.days(from: start, to: end) ?? -1) < 0 { return nil }
            guard raw.title != nil || raw.start != nil || raw.end != nil else { return nil }
            return .updateTrip(tripID: id, title: clean(raw.title, max: AssistantSetting.tripTitleLimit), start: raw.start, end: raw.end)
        case "deleteTrip":
            return clean(raw.tripId, max: 100).map { .deleteTrip(tripID: $0) }
        case "setSetting":
            guard let setting = raw.setting.flatMap(AssistantSetting.init(rawValue:)), let value = raw.value.flatMap(setting.canonical) else { return nil }
            return .setSetting(setting, value: value)
        case "resolvePlaceSuggestion":
            guard raw.decision == "register" || raw.decision == "dismiss" else { return nil }
            let register = raw.decision == "register"
            if raw.name != nil, !register || clean(raw.name, max: AssistantCatalogLimits.placeName) == nil { return nil }
            if raw.kind != nil, !register || raw.kind.flatMap(FrequentPlaceKind.init(rawValue:)) == nil { return nil }
            return .resolvePlaceSuggestion(
                register: register, name: clean(raw.name, max: AssistantCatalogLimits.placeName), kind: raw.kind.flatMap(FrequentPlaceKind.init(rawValue:))
            )
        case "setTripBudget":
            guard let id = clean(raw.tripId, max: 100), let amount = raw.budgetKRW, amount.isFinite, (0...LedgerBudget.assistantLimitKRW).contains(amount) else { return nil }
            return .setTripBudget(tripID: id, budgetKRW: amount.rounded())
        case "setCarAudio":
            guard let name = clean(raw.name, max: 60), let isMyCar = raw.isMyCar else { return nil }
            return .setCarAudio(name: name, isMyCar: isMyCar)
        case "setCalendarTitleDetail":
            guard let title = clean(raw.title, max: 200), let detail = raw.detailId else { return nil }
            if detail == "none" { return .setCalendarTitleDetail(title: title, detailID: nil) }
            let allowed = CalendarTitleClassification.selectableCategories.flatMap(\.details).map(\.id)
            return allowed.contains(detail) ? .setCalendarTitleDetail(title: title, detailID: detail) : nil
        case "requestApproval":
            guard let id = raw.id, let approval = AssistantApproval.make(request: raw.request, value: raw.value) else { return nil }
            return .requestApproval(approval.question(id: id, now: now))
        case "askUser":
            return AssistantQuestion.make(id: raw.id, question: raw.question, options: raw.options, multiSelect: raw.multiSelect, now: now).map { .askUser($0) }
        default:
            return nil
        }
    }

    /// `YYYY-MM`(2000년부터)만 받는다.
    static func month(_ text: String) -> String? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 7, parts.count == 2, parts[0].count == 4, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }),
              let year = Int(parts[0]), let month = Int(parts[1]), year >= 2_000, (1...12).contains(month) else { return nil }
        return text
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
        // ACT1114A07: 여행 가계부·몫을 나누는 사람·메모.
        if raw.tripId != nil, clean(raw.tripId, max: 100) == nil { return nil }
        if raw.note != nil, clean(raw.note, max: 200) == nil { return nil }
        let sharers = raw.shareNames.map { AssistantExpenseChange.sharers($0, minimum: 1) }
        if let sharers, sharers == nil { return nil }
        return .addExpense(LedgerEntry(
            occurredAt: at, amount: amount, currency: currency, kind: kind, category: category,
            title: title, payer: clean(raw.payer, max: 30), tripID: clean(raw.tripId, max: 100), note: clean(raw.note, max: 200), source: .assistant,
            shareNames: sharers ?? nil
        ))
    }

    /// updateExpense(AIQ1111A01): 고칠 칸이 하나라도 있거나 지우기여야 한다. 서버와 같은 규칙.
    static func expenseChange(_ raw: Raw, calendar: Calendar = .autoupdatingCurrent) -> AssistantCommand.Action? {
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
        // ACT1114A07: tripId "none"은 일상 가계부로, shareNames []는 「다 같이」로 돌린다.
        if raw.tripId != nil {
            guard let tripID = clean(raw.tripId, max: 100) else { return nil }
            change.tripID = tripID == "none" ? "" : tripID
        }
        if let names = raw.shareNames {
            guard let sharers = AssistantExpenseChange.sharers(names, minimum: 0) else { return nil }
            change.shareNames = sharers
        }
        if raw.note != nil {
            guard let note = clean(raw.note, max: 200) else { return nil }
            change.note = note
        }
        if let date = raw.date {
            guard day(date, calendar: calendar) != nil else { return nil }
            change.date = date
        }
        if let time = raw.time {
            guard let minutes = minutes(time) else { return nil }
            change.minutes = minutes
        }
        guard change.delete || change != AssistantExpenseChange() else { return nil }
        return .updateExpense(entryID: id, change: change)
    }
}

/// 날짜(`YYYY-MM-DD`)·시각(자정부터의 분)을 따로 옮긴다(ACT1114A07). 날짜만 주면 시각을, 시각만 주면 날짜를 그대로 둔다.
struct AssistantWhenChange: Equatable, Sendable {
    var date: String?
    var minutes: Int?

    var isEmpty: Bool { date == nil && minutes == nil }

    init(date: String? = nil, minutes: Int? = nil) {
        self.date = date
        self.minutes = minutes
    }

    /// 명령의 `date`·`time`에서. 준 칸이 틀리면 nil.
    init?(date: String?, time: String?, calendar: Calendar) {
        if let date, AssistantCommandParser.day(date, calendar: calendar) == nil { return nil }
        let minutes = time.flatMap(AssistantCommandParser.minutes)
        if time != nil, minutes == nil { return nil }
        self.init(date: date, minutes: minutes)
    }

    func applied(to instant: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard !isEmpty else { return instant }
        let day = date.flatMap { AssistantCommandParser.day($0, calendar: calendar) } ?? calendar.startOfDay(for: instant)
        let clock = minutes ?? calendar.component(.hour, from: instant) * 60 + calendar.component(.minute, from: instant)
        return calendar.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: day) ?? instant
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
    /// ACT1114A07: 여행 장부(빈 글이면 일상으로), 몫을 나누는 사람(비면 다 같이), 메모, 새 날짜(`YYYY-MM-DD`)와 시각(자정부터의 분).
    var tripID: String?
    var shareNames: [String]?
    var note: String?
    var date: String?
    var minutes: Int?

    var touchesTrip: Bool { tripID != nil || shareNames != nil }

    func applied(to entry: LedgerEntry, calendar: Calendar = .autoupdatingCurrent) -> LedgerEntry {
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
    static func sharers(_ names: [String], minimum: Int) -> [String]? {
        let cleaned = names.compactMap { AssistantCommandParser.clean($0, max: 30) }
        return cleaned.count == names.count && (minimum...20).contains(names.count) && Set(cleaned).count == cleaned.count ? cleaned : nil
    }

    /// 여행 기록으로 둘 수 없는 까닭: 그 여행 장부가 없거나(`no_trip`), 동행이 아닌 이름으로 나눴다(`no_member`).
    @MainActor
    static func tripProblem(_ entry: LedgerEntry, book: LedgerBook) -> String? {
        guard let tripID = entry.tripID else { return entry.shareNames == nil ? nil : "no_trip" }
        guard let trip = book.trip(tripID) else { return "no_trip" }
        return (entry.shareNames ?? []).allSatisfy(trip.everyone.contains) ? nil : "no_member"
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
    /// 확인 필요·화면 열기 요청(ACX1112A01). 시험은 따로 만든 저장소의 것을 쓴다.
    var review = LedgerReviewStore.shared
    var screens = AssistantScreenRequest.shared
    /// AI가 보낸 질문(ASK1112A01).
    var questions = AssistantQuestionStore.shared

    static var live: Self { Self(defaults: .standard, isLive: true) }

    /// 시험마다 따로 둔 말풍선 파일을 쓴다.
    static func test(_ defaults: UserDefaults) -> Self {
        let name = defaults.string(forKey: "assistantBubbleTestFile") ?? UUID().uuidString
        defaults.set(name, forKey: "assistantBubbleTestFile")
        return Self(
            defaults: defaults, isLive: false, bubbleFile: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json"),
            ledger: LedgerBook(store: { nil }), review: LedgerReviewStore(defaults: defaults), screens: AssistantScreenRequest(defaults: defaults),
            questions: AssistantQuestionStore(defaults: defaults)
        )
    }

    /// 앱 자료 쪽 설정(ACC1112A01)은 `model`이 있어야 읽는다.
    func value(_ key: String, model: AppModel) -> String? {
        if let setting = AssistantSetting.allCases.first(where: { $0.key == key }), setting.isModelBacked { return setting.read(model: model) }
        return value(key)
    }

    func value(_ key: String) -> String? {
        if key == AssistantPreferenceChange.languageKey {
            return isLive ? AppLanguagePreference.current.rawValue : AppLanguagePreference.load(from: defaults).rawValue
        }
        if let setting = AssistantSetting.allCases.first(where: { $0.key == key }) { return setting.read(defaults) }
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
        if let setting = AssistantSetting.allCases.first(where: { $0.key == key }) {
            if setting.isModelBacked {
                if let value, let model { Task { @MainActor in await setting.apply(value, to: model) } }
            } else {
                setting.write(value, defaults: defaults)
            }
            return
        }
        guard AssistantDisplayOption.allCases.contains(where: { $0.defaultsKey == key }) else { return }
        defaults.set(value == "true", forKey: key)
    }
}

/// AI가 열어 달라고 할 수 있는 화면(ACX1112A01). 이 여섯만 받는다. 자료를 바꾸는 화면 동작은 없다.
enum AssistantScreen: String, CaseIterable, Codable, Sendable {
    case paymentAutomation, shortcuts, aiConnection, ledger, dataProtection, settings
    // ACC1112A01
    case salary, carAudio, alarm, placeBook, passport, unconfirmedReview, travel
    // ACT1114A07
    case dayCard, calendarConnect, categoryAdd, paymentAlerts, aiRules

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .paymentAutomation: language.text("BOKKI 결제 자동화 안내", "BOKKI Payment automation guide")
        case .shortcuts: language.text("단축어 · Siri", "Shortcuts · Siri")
        case .aiConnection: language.text("AI 연결", "AI connections")
        case .ledger: language.text("가계부", "Ledger")
        case .dataProtection: language.text("데이터 보호", "Data Protection")
        case .settings: language.text("설정", "Settings")
        case .salary: language.text("급여 설정", "Pay settings")
        case .carAudio: language.text("내 차", "My car")
        case .alarm: language.text("알람 설정", "Alarm settings")
        case .placeBook: language.text("장소 도감", "Place collection")
        case .passport: language.text("여권", "Passport")
        case .unconfirmedReview: language.text("미확인 시간 검토", "Unconfirmed time review")
        case .travel: language.text("여행 모드", "Travel mode")
        case .dayCard: language.text("하루 카드", "Day card")
        case .calendarConnect: language.text("캘린더 연결", "Connect calendar")
        case .categoryAdd: language.text("분류 더하기", "Add categories")
        case .paymentAlerts: language.text("결제 알림 받기", "Payment alerts")
        case .aiRules: language.text("AI 규칙", "AI rules")
        }
    }
}

/// 열어 달라는 화면 하나를 앱이 앞에 올 때까지 둔다(ACX1112A01). 새 요청이 앞의 것을 바꾸고, 하루가 지나면 버린다.
/// 지도 화면의 작은 뷰가 지켜보다 띄운다.
@MainActor
@Observable
final class AssistantScreenRequest {
    static let shared = AssistantScreenRequest()
    static let key = "assistantPendingScreen"
    static let dateKey = "assistantPendingScreenAt"
    static let lifetime: TimeInterval = 86_400

    private(set) var pending: AssistantScreen?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.string(forKey: Self.key).flatMap(AssistantScreen.init(rawValue:))
    }

    func request(_ screen: AssistantScreen, now: Date = .now) {
        defaults.set(screen.rawValue, forKey: Self.key)
        defaults.set(now.timeIntervalSince1970, forKey: Self.dateKey)
        pending = screen
    }

    /// 띄울 화면을 꺼낸다. 오래된 요청은 버린다.
    func take(now: Date = .now) -> AssistantScreen? {
        guard let screen = pending else { return nil }
        let age = now.timeIntervalSince1970 - defaults.double(forKey: Self.dateKey)
        clear()
        return age >= 0 && age < Self.lifetime ? screen : nil
    }

    /// 되돌리기: 아직 띄우지 않은 같은 요청만 거둔다.
    func cancel(_ screen: AssistantScreen) {
        if pending == screen { clear() }
    }

    private func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.dateKey)
        pending = nil
    }
}

/// 명령의 `value`처럼 글자·숫자·참거짓이 다 올 수 있는 칸(ACB1112A01).
enum AssistantLooseValue: Decodable, Equatable, Sendable {
    case flag(Bool)
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .text(try value.decode(String.self)) }
    }
}

/// AI가 바꿀 수 있는 기기 설정(ACB1112A01). 이 이름만 받고, 값은 형과 범위를 본 뒤 정해진 글자 꼴로 다룬다.
/// 급여 금액도 읽기·바꾸기 모두 된다(대표 결정 2026-11-12, PAY1112A01).
enum AssistantSetting: String, CaseIterable, Codable, Sendable {
    case tollVehicle, salaryMode, annualPay, monthlyPay, payIsNet, showsNetPay, hourlyPay, hourlyPayIsNet, hourlyTax, weeklyHolidayPay
    /// ACC1112A01: 앱 자료에 있는 설정. 화면의 설정 함수로 바꾼다. 알림은 끄기만 받는다(켜기는 iOS 권한 창이 필요하다).
    case reduceMotion, weather, weatherSidebar, gpsIntervalSeconds, cat, notifications
    /// ACT1114A07: 지도에 보일 메모(지도 화면 `@AppStorage`와 같은 키).
    case memoDisplay
    /// ACT1114A09: 보폭(cm, 보폭 보정 화면과 같은 키), Watch 수집 단계, 위치 수집·사진은 끄기만(켜기는 iOS 권한 창이 필요하다).
    case strideCentimeters, watchAcceleration, watchDataSync, location, photos

    static let tripTitleLimit = 60
    /// Watch 수집 단계 이름. 차례가 `TaptionWatchAccelerationProfile`·`TaptionWatchDataSyncProfile`의 값이다.
    static let watchProfiles = ["off", "batterySaver", "balanced", "accuracy"]

    private enum Kind {
        case choice([String])
        case amount(Double)
        case flag
        /// 정해진 간격의 정수.
        case count(ClosedRange<Int>, step: Int)
        /// 끄기만.
        case offOnly
    }

    /// 급여 쪽 설정. 연봉 카운터의 「AI 연동」을 끄면 올리지도 바꾸지도 않는다(PAY1112A02).
    var isSalary: Bool {
        switch self {
        case .salaryMode, .annualPay, .monthlyPay, .payIsNet, .showsNetPay, .hourlyPay, .hourlyPayIsNet, .hourlyTax, .weeklyHolidayPay: true
        default: false
        }
    }

    /// 앱 자료(`snapshot.settings`)에 있어 모델의 설정 함수로 바꾸는 것.
    var isModelBacked: Bool {
        switch self {
        case .reduceMotion, .weather, .weatherSidebar, .gpsIntervalSeconds, .cat, .notifications: true
        case .watchAcceleration, .watchDataSync, .location, .photos: true
        default: false
        }
    }


    var key: String {
        switch self {
        case .tollVehicle: LedgerTollDiscount.vehicleKey
        case .salaryMode: MapHomeSalaryPolicy.isHourlyKey
        case .annualPay: MapHomeSalaryPolicy.annualKey
        case .monthlyPay: MapHomeSalaryPolicy.monthlyPayKey
        case .payIsNet: MapHomeSalaryPolicy.isNetInputKey
        case .showsNetPay: MapHomeSalaryPolicy.showsNetKey
        case .hourlyPay: MapHomeSalaryPolicy.hourlyKey
        case .hourlyPayIsNet: MapHomeSalaryPolicy.hourlyIsNetKey
        case .hourlyTax: MapHomeSalaryPolicy.hourlyTaxKey
        case .weeklyHolidayPay: MapHomeSalaryPolicy.weeklyHolidayKey
        case .reduceMotion, .weather, .weatherSidebar, .gpsIntervalSeconds, .cat, .notifications: "appSetting.\(rawValue)"
        case .watchAcceleration, .watchDataSync, .location, .photos: "appSetting.\(rawValue)"
        case .memoDisplay: "mapHomeMemoDisplay"
        case .strideCentimeters: MapHomeStride.storageKey
        }
    }

    private var kind: Kind {
        switch self {
        case .tollVehicle: .choice(LedgerTollDiscount.Vehicle.allCases.map(\.rawValue))
        case .salaryMode: .choice(["salary", "hourly"])
        case .hourlyTax: .choice(MapHomeSalaryPolicy.HourlyTax.allCases.map(\.rawValue))
        case .annualPay: .amount(1e11)
        case .monthlyPay: .amount(1e10)
        case .hourlyPay: .amount(1e7)
        case .payIsNet, .showsNetPay, .hourlyPayIsNet, .weeklyHolidayPay: .flag
        case .reduceMotion, .weather, .weatherSidebar: .flag
        case .gpsIntervalSeconds: .count(GPSLoggingPreferences.intervalStepSeconds...1_800, step: GPSLoggingPreferences.intervalStepSeconds)
        case .cat: .choice(CatCoat.characters.map(\.catStyle.rawValue))
        case .notifications: .offOnly
        case .memoDisplay: .choice(MapHomeMemoDisplayMode.allCases.map(\.rawValue))
        case .strideCentimeters: .count(30...150, step: 1)
        case .watchAcceleration, .watchDataSync: .choice(Self.watchProfiles)
        case .location, .photos: .offOnly
        }
    }

    /// 받은 값을 정해진 글자 꼴로. 형이나 범위가 틀리면 nil.
    func canonical(_ value: AssistantLooseValue) -> String? {
        switch (kind, value) {
        case let (.choice(names), .text(text)): names.contains(text) ? text : nil
        case let (.amount(limit), .number(number)): number.isFinite && (0...limit).contains(number) ? String(number.rounded()) : nil
        case let (.flag, .flag(flag)): String(flag)
        case let (.count(range, step), .number(number)):
            number == number.rounded() && range.contains(Int(number)) && Int(number) % step == 0 ? String(Int(number)) : nil
        case (.offOnly, .flag(false)): "false"
        default: nil
        }
    }

    /// 앱 자료 쪽 설정의 지금 값.
    @MainActor
    func read(model: AppModel) -> String? {
        let settings = model.snapshot.settings
        switch self {
        case .reduceMotion: return String(settings.reduceMotion)
        case .weather: return String(settings.weatherEnabled)
        case .weatherSidebar: return String(settings.weatherSidebarVisible)
        case .gpsIntervalSeconds: return String(settings.gpsLoggingPreferences.intervalSeconds)
        case .cat: return settings.catStyle.rawValue
        case .notifications: return String(settings.notificationsEnabled)
        case .watchAcceleration: return Self.watchProfiles.indices.contains(settings.watchAccelerationProfile.rawValue) ? Self.watchProfiles[settings.watchAccelerationProfile.rawValue] : nil
        case .watchDataSync: return Self.watchProfiles.indices.contains(settings.watchDataSyncProfile.rawValue) ? Self.watchProfiles[settings.watchDataSyncProfile.rawValue] : nil
        case .location: return String(settings.locationEnabled)
        case .photos: return String(settings.showsPhotos)
        default: return nil
        }
    }

    /// 화면의 설정 함수로 바꾼다(부수 동작까지 같다: Watch 알림, 수집 설정 다시 맞추기, 예약 알림 지우기).
    @MainActor
    func apply(_ value: String, to model: AppModel) async {
        switch self {
        case .reduceMotion: model.setReduceMotion(value == "true")
        case .weather: await model.setWeatherEnabled(value == "true")
        case .weatherSidebar: model.setWeatherSidebarVisible(value == "true")
        case .gpsIntervalSeconds: if let seconds = Int(value) { model.setGPSLoggingIntervalSeconds(seconds) }
        case .cat: if let coat = CatCoat.characters.first(where: { $0.catStyle.rawValue == value }) { model.selectCatCoat(coat) }
        case .notifications: await model.setNotificationsEnabled(value == "true")
        case .watchAcceleration:
            if let profile = Self.watchProfiles.firstIndex(of: value).flatMap(TaptionWatchAccelerationProfile.init(rawValue:)) { model.setWatchAccelerationProfile(profile) }
        case .watchDataSync:
            if let profile = Self.watchProfiles.firstIndex(of: value).flatMap(TaptionWatchDataSyncProfile.init(rawValue:)) { model.setWatchDataSyncProfile(profile) }
        // 끄기는 설정의 스위치와 같은 함수. 되돌리기(켜기)는 사용자가 누른 것이라 권한 창이 떠도 된다.
        case .location:
            if value == "true" { await model.enableLocationCollection() } else { await model.disableLocationCollection() }
        case .photos: await model.setPhotosEnabled(value == "true")
        default: break
        }
    }

    /// 지금 값. 한 번도 정하지 않았으면 nil.
    func read(_ defaults: UserDefaults) -> String? {
        guard !isModelBacked, let stored = defaults.object(forKey: key) else { return nil }
        if self == .strideCentimeters {
            return (stored as? Double).flatMap { MapHomeStride.allowedRange.contains($0) ? String(Int(($0 * 100).rounded())) : nil }
        }
        switch kind {
        case .count, .offOnly: return nil
        case .choice where self == .salaryMode: return (stored as? Bool).map { $0 ? "hourly" : "salary" }
        case .choice: return stored as? String
        case .amount: return (stored as? Double).map { String($0.rounded()) }
        case .flag: return (stored as? Bool).map(String.init)
        }
    }

    /// nil이면 정하기 전으로 돌린다.
    func write(_ value: String?, defaults: UserDefaults) {
        guard !isModelBacked else { return }
        guard let value else { return defaults.removeObject(forKey: key) }
        if self == .strideCentimeters { return defaults.set((Double(value) ?? 0) / 100, forKey: key) }
        switch kind {
        case .count, .offOnly: break
        case .choice where self == .salaryMode: defaults.set(value == "hourly", forKey: key)
        case .choice: defaults.set(value, forKey: key)
        case .amount: defaults.set(Double(value) ?? 0, forKey: key)
        case .flag: defaults.set(value == "true", forKey: key)
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .tollVehicle: language.text("통행료 차종", "Toll vehicle")
        case .salaryMode: language.text("급여 방식", "Pay type")
        case .annualPay: language.text("연봉", "Annual pay")
        case .monthlyPay: language.text("월급", "Monthly pay")
        case .payIsNet: language.text("급여를 세후로 입력", "Pay entered after tax")
        case .showsNetPay: language.text("세후 금액으로 보기", "Show after-tax amounts")
        case .hourlyPay: language.text("시급", "Hourly pay")
        case .hourlyPayIsNet: language.text("시급을 세후로 입력", "Hourly pay entered after tax")
        case .hourlyTax: language.text("시급 세금 방식", "Hourly tax method")
        case .weeklyHolidayPay: language.text("주휴수당 포함", "Weekly holiday pay")
        case .reduceMotion: language.text("움직임 줄이기", "Reduce motion")
        case .weather: language.text("날씨", "Weather")
        case .weatherSidebar: language.text("날씨 옆 칸", "Weather sidebar")
        case .gpsIntervalSeconds: language.text("위치 기록 간격(초)", "Location logging interval (s)")
        case .cat: language.text("고양이", "Cat")
        case .notifications: language.text("알림", "Notifications")
        case .memoDisplay: language.text("메모 표시", "Show memos")
        case .strideCentimeters: language.text("보폭(cm)", "Stride (cm)")
        case .watchAcceleration: language.text("Watch 움직임 수집", "Watch motion collection")
        case .watchDataSync: language.text("Watch 자료 보내기", "Watch data sync")
        case .location: language.text("위치 수집", "Location logging")
        case .photos: language.text("사진 보기", "Photos")
        }
    }
}
