import Foundation
import TaptionPlanCore

/// AI 비서가 보낸 명령 하나(TRP1110A07). 앱이 열릴 때 묻지 않고 반영하고 알림만 남긴다(대표 결정).
struct AssistantCommand: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case addMemo(text: String, at: Date)
        case addSchedule(title: String, start: Date, end: Date?, note: String?, extras: AssistantScheduleExtras = .init())
        /// 하루 안의 기록 하나를 고친다. id가 없으면 `startTime`을 덮는 기록을 찾는다.
        case updateActivity(day: Date, recordID: String?, startTime: Date?, title: String?, categoryID: String?)
        /// 자동 기록을 미확인(유령)으로 교정해 가린다. 원본 행은 남는다(CLN1110A01).
        case hideRecord(day: Date, recordID: String?, startTime: Date?)
        /// 이어진 기록 2~20개를 사용자 덮개 기록 하나로 합친다(CLN1110A01).
        case mergeRecords(day: Date, recordIDs: [String], title: String?, categoryID: String?)
        /// 표시 시간만 교정표로 바꾼다. 시각은 그날의 HH:mm(CLN1110A01).
        case updateRecordTime(day: Date, recordID: String, start: Date?, end: Date?)
        case updateSchedule(
            target: AssistantPlanTarget, title: String?, start: AssistantScheduleTime?, end: AssistantScheduleTime?, note: String?,
            extras: AssistantScheduleExtras = .init()
        )
        case deleteSchedule(target: AssistantPlanTarget)
        case updateMemo(memoID: String, text: String)
        case deleteMemo(memoID: String)
        /// 루틴(상위 계획)·여행 일정·수면·안전한 표시 설정(AIR1110A03). 모두 되돌릴 수 있는 사용자 편집이다.
        case addGoal(title: String, start: Date, end: Date, categoryID: String?)
        case updateGoal(goalID: String, title: String?, start: Date?, end: Date?, categoryID: String?)
        case deleteGoal(goalID: String)
        /// 좌표가 없으면 이름으로 찾는다. `tripID`를 주면 그 여행에 붙인다(REV1110A06).
        case addTripStop(title: String, day: Date, coordinate: AssistantCoordinate?, status: TripItemStatus?, tripID: String?)
        case updateTripStop(stopID: String, title: String?, day: Date?, order: Int?, status: TripItemStatus?)
        case deleteTripStop(stopID: String)
        case setTripItemStatus(tripID: String, itemID: String, status: TripItemStatus)
        case updateSleep(recordID: String, start: AssistantScheduleTime?, end: AssistantScheduleTime?)
        case setLanguage(AppLanguagePreference)
        case setMapStyle(MapDisplayStyle)
        case setDisplayOption(AssistantDisplayOption, enabled: Bool)
        /// 그날 그 시각 사이 화랑이 말풍선 글(BUB1110A01). 기록은 바꾸지 않는다.
        case setBubble(start: Date, end: Date, text: String, kind: AssistantBubble.Kind = .routine)
        /// 가계부 기록 하나(LED1110A01). 되돌리면 지운다.
        case addExpense(LedgerEntry)
        /// AIQ1111A01: 있는 가계부 기록 고치기·지우기. nil인 칸은 그대로 둔다.
        case updateExpense(entryID: UUID, change: AssistantExpenseChange)
        /// ACT1111A01: 앱이 분류하지 못한 시간을 분류로 채운다. 아직 미확인인 부분만 사용자 기록으로 남는다.
        case classifyUnconfirmed(start: Date, end: Date, title: String?, categoryID: String)
        /// ACT1111A01: 이동 구간 하나의 수단을 사용자 교정으로 바꾼다.
        /// RDQ1114A01: `line`은 버스 번호나 지하철 노선(없어도 됨).
        case setTravelMode(moveID: UUID, mode: TravelMode, line: String? = nil)
        /// PRL1112A01: 결제 문자 읽기 규칙. 견본과 맞는지 본 것만 담는다.
        case addPaymentRule(LedgerMessageRules.Rule)
        /// ACX1112A01: 가계부 설정과 정리, 화면 열기. 0원은 그 달 예산을 없앤다.
        case setBudget(month: String, amountKRW: Double)
        case addOwnAccount(String)
        case removeOwnAccount(String)
        case deletePaymentRule(UUID)
        /// 「확인 필요」 하나를 가계부에 넣거나(`add`) 버린다.
        case resolveReview(UUID, add: Bool)
        case deleteInboxItem(UUID)
        /// 앱이 앞에 있을 때 화면을 띄운다. 자료는 바꾸지 않는다.
        case openScreen(AssistantScreen)
        /// ASK1112A01: 앱에서 객관식으로 묻는다. 기록은 바꾸지 않고, 답은 앱이 서버에 올린다.
        case askUser(AssistantQuestion)
        /// ACA1112A01: 자주 가는 장소와 분류. nil인 칸은 그대로 둔다. 좌표는 받기만 한다.
        case addPlace(name: String, coordinate: AssistantCoordinate?, radius: Double?, autoRecord: Bool?)
        case updatePlace(placeID: UUID, name: String?, coordinate: AssistantCoordinate?, radius: Double?, autoRecord: Bool?)
        case deletePlace(UUID)
        case addCategory(name: String, color: String, icon: CategoryIcon?)
        case updateCategory(categoryID: String, name: String?, color: String?, icon: CategoryIcon?, hidden: Bool?)
        /// ACB1112A01: 여행 만들기·고치기·지우기와 기기 설정 하나 바꾸기(값은 정해진 글자 꼴).
        case addTrip(TravelTrip)
        case updateTrip(tripID: String, title: String?, start: String?, end: String?)
        case deleteTrip(tripID: String)
        case setSetting(AssistantSetting, value: String)
        /// ACD1112A01: 혼자 할 수 없는 일의 승인 요청. 앱에서 승인해야 실행된다.
        case requestApproval(AssistantQuestion)
        /// HND1112A01: 앱의 「확인할 것」을 끝낸다 — 자주 머무는 곳 제안, 내 차, 일정 제목 분류(`detailID` nil은 분류 안 함).
        case resolvePlaceSuggestion(register: Bool, name: String?, kind: FrequentPlaceKind?)
        case setCarAudio(name: String, isMyCar: Bool)
        case setCalendarTitleDetail(title: String, detailID: String?)
        /// TBG1112A01: 여행 예산(원). 0이면 예산 없음.
        case setTripBudget(tripID: String, budgetKRW: Double)
        /// ACT1114A07: 등록부(`AssistantOperations`)의 동작. 새 동작은 이 한 줄로 다 받는다.
        case operation(AssistantParsedOperation)
    }

    let id: String
    let action: Action
    /// 보낸 연결 키 id(키 해시 앞 8글자)와 방식 "rest"·"mcp"·"oauth"(SEC1110A02).
    var keyID: String? = nil
    var source: String? = nil
    /// 이 명령이 어느 맡긴 일 때문에 온 것인지(AIP1114A05). AI가 붙여 보낸 일 id.
    var taskID: String? = nil
}

struct AssistantCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

struct AssistantCommandBatch: Equatable, Sendable {
    var commands: [AssistantCommand]
    /// 형식이 틀린 명령. 반영하지 않고 거절로 알린다.
    var invalidIDs: [String]
    /// 형식이 틀린 명령 가운데 종류를 아는 것(AIP1114A05). 「AI가 한 일」에 거절로 남길 때 쓴다.
    var invalidInfo: [String: Invalid] = [:]

    struct Invalid: Equatable, Sendable {
        var kind: AssistantActionKind
        var keyID: String?
        var source: String?
        var taskID: String?
    }
}

enum AssistantCommandParser {
    private struct Envelope: Decodable { let commands: [Item] }

    /// 명령 하나씩 따로 읽는다. 칸 하나의 형이 틀려도 그 명령만 틀린 것으로 돌리고 나머지는 받는다(REV1110A06).
    private struct Item: Decodable {
        private enum Key: String, CodingKey { case id }
        let raw: Raw?
        let id: String?
        /// 칸을 이름으로 읽는 꼴(ACT1114A07). 등록부 동작은 이것만 본다.
        let values: [String: AssistantJSON]?

        init(from decoder: Decoder) throws {
            values = try? decoder.singleValueContainer().decode([String: AssistantJSON].self)
            raw = try? Raw(from: decoder)
            id = raw?.id ?? (try? decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: .id)) ?? nil
        }
    }

    struct Raw: Decodable {
        let id: String?, format: String?, version: Int?, action: String?
        let text: String?, date: String?, time: String?
        let title: String?, start: String?, end: String?, note: String?
        let recordId: String?, startTime: String?, categoryId: String?
        let recordIds: [String]?, planId: String?, memoId: String?
        // AIR1110A03·SEC1110A02
        let keyId: String?, source: String?
        let goalId: String?, stopId: String?, tripId: String?, itemId: String?, status: String?, order: Int?
        let latitude: Double?, longitude: Double?, lat: Double?, lng: Double?
        let language: String?, mapStyle: String?, theme: String?, option: String?, enabled: Bool?
        // BUB1110A02: setBubble의 routine|event.
        let kind: String?
        // LED1110A01: addExpense.
        let amount: Double?, currency: String?, category: String?, payer: String?
        // AIQ1111A01: updateExpense.
        let entryId: String?, delete: Bool?
        // ACT1111A01: setTravelMode.
        let moveId: String?, mode: String?, line: String?
        // PRL1112A01: addPaymentRule.
        let name: String?, pattern: String?, sample: String?
        // ACX1112A01: setBudget·deletePaymentRule·resolveReview·deleteInboxItem·openScreen.
        let amountKRW: Double?, month: String?, ruleId: String?, reviewId: String?, decision: String?, inboxId: String?, screen: String?
        // ASK1112A01: askUser.
        let question: String?, options: [String]?, multiSelect: Bool?
        // ACA1112A01: 장소·분류.
        let placeId: String?, radius: Double?, autoRecord: Bool?, color: String?, icon: String?, hidden: Bool?
        // ACB1112A01: 여행·설정.
        let wishDays: Int?, countryCode: String?, regionName: String?, setting: String?, value: AssistantLooseValue?
        // ACD1112A01: requestApproval.
        let request: String?
        // HND1112A01: setCarAudio·setCalendarTitleDetail.
        let isMyCar: Bool?, detailId: String?
        // TBG1112A01: setTripBudget.
        let budgetKRW: Double?
        // AIP1114A05: 이 명령이 딸린 맡긴 일.
        let taskId: String?
        // ACT1114A07: addExpense·updateExpense의 몫을 나누는 사람.
        let shareNames: [String]?
        // ACT1114A07: addSchedule·updateSchedule의 중요·상위 루틴.
        let important: Bool?, parentGoalId: String?
    }

    /// `{"commands":[...]}`를 읽는다. 서버와 같은 규칙으로 다시 본다.
    static func parse(_ data: Data, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> AssistantCommandBatch? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var batch = AssistantCommandBatch(commands: [], invalidIDs: [])
        for item in envelope.commands {
            guard let id = item.id, !id.isEmpty, !id.contains(",") else { continue }
            if let fields = item.values.map({ AssistantFields(values: $0, now: now, calendar: calendar) }),
               let name = fields.name, AssistantOperations.spec(name) != nil {
                let keyID = fields.text("keyId", max: 64), source = fields.text("source", max: 16), taskID = fields.text("taskId", max: 100)
                if let parsed = AssistantOperations.parse(fields) {
                    batch.commands.append(AssistantCommand(id: id, action: .operation(parsed), keyID: keyID, source: source, taskID: taskID))
                } else {
                    batch.invalidIDs.append(id)
                    batch.invalidInfo[id] = .init(kind: .operation(name), keyID: keyID, source: source, taskID: taskID)
                }
                continue
            }
            if let raw = item.raw, raw.format == "bokki-command", raw.version == 1, let action = action(raw, now: now, calendar: calendar) {
                batch.commands.append(AssistantCommand(
                    id: id, action: action, keyID: clean(raw.keyId, max: 64), source: clean(raw.source, max: 16), taskID: clean(raw.taskId, max: 100)
                ))
            } else {
                batch.invalidIDs.append(id)
                if let raw = item.raw, let kind = raw.action.flatMap(AssistantActionKind.init(rawValue:)) {
                    batch.invalidInfo[id] = .init(kind: kind, keyID: clean(raw.keyId, max: 64), source: clean(raw.source, max: 16), taskID: clean(raw.taskId, max: 100))
                }
            }
        }
        return batch
    }

    private static func action(_ raw: Raw, now: Date, calendar: Calendar) -> AssistantCommand.Action? {
        switch raw.action {
        case "addMemo":
            guard let text = clean(raw.text, max: 2_000),
                  let at = memoInstant(date: raw.date, time: raw.time, now: now, calendar: calendar) else { return nil }
            return .addMemo(text: text, at: at)
        case "addSchedule":
            guard let title = clean(raw.title, max: 200), let start = raw.start.flatMap(instant) else { return nil }
            let end = raw.end.flatMap(instant)
            if raw.end != nil, end.map({ $0 > start }) != true { return nil }
            if let note = raw.note, note.count > 2_000 { return nil }
            guard let extras = scheduleExtras(raw, allowsDetach: false) else { return nil }
            return .addSchedule(title: title, start: start, end: end, note: clean(raw.note, max: 2_000), extras: extras)
        case "updateActivity":
            guard let date = raw.date, let day = self.day(date, calendar: calendar) else { return nil }
            let title = clean(raw.title, max: 100), categoryID = clean(raw.categoryId, max: 100)
            let recordID = clean(raw.recordId, max: 100)
            var startTime: Date?
            if let time = raw.startTime {
                guard let value = clock(time, on: day, calendar: calendar) else { return nil }
                startTime = value
            }
            guard title != nil || categoryID != nil, recordID != nil || startTime != nil else { return nil }
            return .updateActivity(day: day, recordID: recordID, startTime: startTime, title: title, categoryID: categoryID)
        default:
            return editAction(raw, calendar: calendar)
        }
    }

    /// 기존 항목을 고치는 명령(AIR1110A02·CLN1110A01). 서버와 같은 규칙으로 다시 본다.
    private static func editAction(_ raw: Raw, calendar: Calendar) -> AssistantCommand.Action? {
        let day = raw.date.flatMap { self.day($0, calendar: calendar) }
        if raw.date != nil, day == nil { return nil }
        let recordID = clean(raw.recordId, max: 100)
        switch raw.action {
        case "hideRecord":
            guard let day else { return nil }
            var startTime: Date?
            if let time = raw.startTime {
                guard let value = clock(time, on: day, calendar: calendar) else { return nil }
                startTime = value
            }
            guard recordID != nil || startTime != nil else { return nil }
            return .hideRecord(day: day, recordID: recordID, startTime: startTime)
        case "mergeRecords":
            guard let day, let raws = raw.recordIds, (2...20).contains(raws.count) else { return nil }
            let ids = raws.compactMap { clean($0, max: 100) }
            guard ids.count == raws.count, Set(ids).count == ids.count else { return nil }
            if raw.title != nil, clean(raw.title, max: 100) == nil { return nil }
            return .mergeRecords(day: day, recordIDs: ids, title: clean(raw.title, max: 100), categoryID: clean(raw.categoryId, max: 100))
        case "updateRecordTime":
            guard let day, let recordID else { return nil }
            let start = raw.start.map { clock($0, on: day, calendar: calendar) }
            let end = raw.end.map { clock($0, on: day, calendar: calendar) }
            guard start != nil || end != nil, start.map({ $0 != nil }) ?? true, end.map({ $0 != nil }) ?? true else { return nil }
            return .updateRecordTime(day: day, recordID: recordID, start: start ?? nil, end: end ?? nil)
        case "updateSchedule":
            guard let target = planTarget(raw, day: day, calendar: calendar) else { return nil }
            let start = raw.start.map(AssistantScheduleTime.init(text:)), end = raw.end.map(AssistantScheduleTime.init(text:))
            guard start.map({ $0 != nil }) ?? true, end.map({ $0 != nil }) ?? true else { return nil }
            if raw.title != nil, clean(raw.title, max: 200) == nil { return nil }
            if let note = raw.note, note.count > 2_000 { return nil }
            let title = clean(raw.title, max: 200), note = clean(raw.note, max: 2_000)
            guard let extras = scheduleExtras(raw, allowsDetach: true) else { return nil }
            guard title != nil || start != nil || end != nil || note != nil || !extras.isEmpty else { return nil }
            return .updateSchedule(target: target, title: title, start: start ?? nil, end: end ?? nil, note: note, extras: extras)
        case "deleteSchedule":
            return planTarget(raw, day: day, calendar: calendar).map { .deleteSchedule(target: $0) }
        case "updateMemo":
            guard let memoID = clean(raw.memoId, max: 100), let text = clean(raw.text, max: 2_000) else { return nil }
            return .updateMemo(memoID: memoID, text: text)
        case "deleteMemo":
            return clean(raw.memoId, max: 100).map { .deleteMemo(memoID: $0) }
        default:
            return dataAction(raw, day: day, calendar: calendar)
        }
    }

    /// 일정의 분류·중요·상위 루틴(ACT1114A07). 틀린 칸이 있으면 nil. `parentGoalId` "none"은 고칠 때만 받는다.
    private static func scheduleExtras(_ raw: Raw, allowsDetach: Bool) -> AssistantScheduleExtras? {
        if raw.categoryId != nil, clean(raw.categoryId, max: 100) == nil { return nil }
        var parent: String?
        if let text = raw.parentGoalId {
            if allowsDetach, text == "none" { parent = "" } else if UUID(uuidString: text) != nil { parent = text } else { return nil }
        }
        return AssistantScheduleExtras(categoryID: clean(raw.categoryId, max: 100), important: raw.important, parentGoalID: parent)
    }

    /// `planId`, 없으면 `date`+`startTime`으로 일정을 고른다.
    private static func planTarget(_ raw: Raw, day: Date?, calendar: Calendar) -> AssistantPlanTarget? {
        if let planID = clean(raw.planId, max: 100) { return AssistantPlanTarget(planID: planID, startTime: nil) }
        guard let day, let time = raw.startTime, let startTime = clock(time, on: day, calendar: calendar) else { return nil }
        return AssistantPlanTarget(planID: nil, startTime: startTime)
    }

    static func clean(_ value: String?, max: Int) -> String? {
        guard let value, value.count <= max else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 시각이 없으면 오늘은 지금, 다른 날은 정오에 놓는다.
    static func memoInstant(date: String?, time: String?, now: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: now)
        if let date {
            guard let parsed = self.day(date, calendar: calendar) else { return nil }
            day = parsed
        }
        guard let time else { return calendar.isDate(day, inSameDayAs: now) ? now : day.addingTimeInterval(12 * 3_600) }
        return clock(time, on: day, calendar: calendar)
    }

    static func day(_ text: String, calendar: Calendar) -> Date? {
        guard let parts = numbers(text, separator: "-", count: 3), parts[0] >= 2_000,
              (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func clock(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        guard let parts = numbers(text, separator: ":", count: 2), (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private static func numbers(_ text: String, separator: Character, count: Int) -> [Int]? {
        let parts = text.split(separator: separator, omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == count, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// `2026-11-12T15:00+09:00`(초·Z도 받는다).
    static func instant(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// 이미 처리한 명령 id. 서버에서 지운 뒤에도 캐시가 잠깐 예전 목록을 줄 수 있어 두 번 반영하지 않는다.
enum AssistantCommandLedger {
    static let defaultsKey = "assistantCommandHandledIDs"
    static let limit = 200

    static func handled(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func remember(_ ids: [String], defaults: UserDefaults = .standard) {
        let old = handled(defaults).filter { !ids.contains($0) }
        defaults.set(Array((old + ids).suffix(limit)), forKey: defaultsKey)
    }

    static func unseen(_ batch: AssistantCommandBatch, defaults: UserDefaults = .standard) -> AssistantCommandBatch {
        let seen = Set(handled(defaults))
        return AssistantCommandBatch(
            commands: batch.commands.filter { !seen.contains($0.id) },
            invalidIDs: batch.invalidIDs.filter { !seen.contains($0) }, invalidInfo: batch.invalidInfo
        )
    }
}

/// 고칠 기록 찾기와 교정 값. 자동 원본은 그대로 두고 교정표에만 쓴다.
enum AssistantActivityTarget {
    static func record(
        id: String?, at instant: Date?, day: Date, in actuals: [ActualRecord],
        now: Date = .now, calendar: Calendar = .autoupdatingCurrent
    ) -> ActualRecord? {
        if let id {
            return UUID(uuidString: id).flatMap { uuid in actuals.first { $0.id == uuid } }
        }
        guard let instant, calendar.isDate(instant, inSameDayAs: day) else { return nil }
        // 덮는 기록이 여럿이면 늦게 시작한(더 자세한) 것을 고친다.
        return actuals
            .filter { $0.categoryID != "unconfirmed" && $0.startedAt <= instant && instant < $0.span(asOf: now).end }
            .max { $0.startedAt < $1.startedAt }
    }

    static func option(for actual: ActualRecord, title: String?, categoryID: String?) -> ActivityCorrectionOption {
        let newTitle = title ?? actual.title
        return ActivityCorrectionOption(
            id: "assistant.\(newTitle)",
            title: newTitle,
            behavior: title == nil ? actual.behavior : nil,
            categoryID: categoryID ?? actual.categoryID,
            systemImage: "tag.fill",
            isAutomatic: false,
            isCustom: false
        )
    }
}

struct AssistantCommandOutcome: Equatable, Sendable {
    struct Result: Equatable, Sendable {
        var id: String
        var applied: Bool
        var reason: String?
    }

    var results: [Result] = []
    var memos = 0
    var schedules = 0
    var edits = 0
    var settings = 0
    var bubbles = 0
    var ledger = 0
    var questions = 0
    /// 「AI가 한 일」에 남길 항목(AIR1110A02).
    var entries: [AssistantLogEntry] = []

    mutating func count(_ kind: AssistantActionKind) {
        switch kind {
        case .addMemo, .updateMemo, .deleteMemo: memos += 1
        case .addSchedule, .updateSchedule, .deleteSchedule: schedules += 1
        case .addGoal, .updateGoal, .deleteGoal, .addTripStop, .updateTripStop, .deleteTripStop, .setTripItemStatus: schedules += 1
        case .updateActivity, .hideRecord, .mergeRecords, .updateRecordTime, .updateSleep, .classifyUnconfirmed, .setTravelMode: edits += 1
        case .setLanguage, .setMapStyle, .setDisplayOption, .addPaymentRule: settings += 1
        case .setBudget, .addOwnAccount, .removeOwnAccount, .deletePaymentRule, .deleteInboxItem, .openScreen: settings += 1
        case .resolveReview, .setTripBudget: ledger += 1
        case .askUser, .requestApproval: questions += 1
        case .addPlace, .updatePlace, .deletePlace, .addCategory, .updateCategory, .setSetting: settings += 1
        case .resolvePlaceSuggestion, .setCarAudio, .setCalendarTitleDetail: settings += 1
        case .addTrip, .updateTrip, .deleteTrip: schedules += 1
        case .setBubble: bubbles += 1
        case .addExpense, .updateExpense: ledger += 1
        case let .operation(name):
            switch AssistantOperations.spec(name)?.counter ?? .settings {
            case .memos: memos += 1
            case .schedules: schedules += 1
            case .edits: edits += 1
            case .settings: settings += 1
            case .ledger: ledger += 1
            }
        }
    }

    var rejected: Int { results.filter { !$0.applied }.count }

    func notice(_ language: MapHomeLanguage) -> String? {
        guard !results.isEmpty else { return nil }
        var parts: [String] = []
        if memos > 0 { parts.append(language.text("메모 \(memos)개", "\(memos) memo(s)")) }
        if schedules > 0 { parts.append(language.text("일정 \(schedules)개", "\(schedules) schedule(s)")) }
        if edits > 0 { parts.append(language.text("기록 수정 \(edits)개", "\(edits) record edit(s)")) }
        if settings > 0 { parts.append(language.text("설정 \(settings)개", "\(settings) setting(s)")) }
        if bubbles > 0 { parts.append(language.text("말풍선 \(bubbles)개", "\(bubbles) bubble(s)")) }
        if ledger > 0 { parts.append(language.text("가계부 \(ledger)개", "\(ledger) ledger entr(ies)")) }
        if questions > 0 { parts.append(language.text("질문 \(questions)개", "\(questions) question(s)")) }
        if rejected > 0 { parts.append(language.text("못 한 것 \(rejected)개", "\(rejected) not done")) }
        return language.text("AI 비서 요청을 반영했어요", "Applied AI assistant requests") + ": " + parts.joined(separator: " · ")
    }
}

extension TripRelay {
    @MainActor
    private static func commandRequest(
        _ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, env: AssistantRegistration.Environment,
        timeout: TimeInterval = 10
    ) -> URLRequest? {
        env.secrets.read(.master).flatMap { relayRequest(path, method: method, query: query, body: body, token: $0, host: env.host, timeout: timeout) }
    }

    static let commandFetchTimeout: TimeInterval = 5

    @MainActor
    static func fetchCommands(env: AssistantRegistration.Environment = .live) async -> AssistantCommandBatch? {
        // 화면에서 기다리는 요청이라 5초 안에 끝낸다(SYN1111A01).
        guard let (response, data) = await sendResponse(commandRequest("/command", method: "GET", env: env, timeout: commandFetchTimeout), session: env.session)
        else { return nil }
        // AI가 대화 중인지 알려 주는 머리 값으로 다음 확인 간격을 정한다(SYN1111A03).
        if let signal = AssistantCommandPolling.signal(from: response) { AssistantCommandPolling.signal = signal }
        if response.statusCode == 204 { return AssistantCommandBatch(commands: [], invalidIDs: []) }
        return response.statusCode == 200 ? AssistantCommandParser.parse(data) : nil
    }

    /// 결과를 AI가 볼 수 있게 남긴다. 서버가 받았을 때만 true.
    @MainActor
    static func postResults(_ results: [AssistantCommandOutcome.Result], env: AssistantRegistration.Environment = .live) async -> Bool {
        let body = try? JSONSerialization.data(withJSONObject: ["results": results.map { result -> [String: String] in
            var value = ["id": result.id, "status": result.applied ? "applied" : "rejected"]
            if let reason = result.reason { value["reason"] = reason }
            return value
        }])
        let reply = await send(commandRequest("/command/result", method: "POST", body: body, env: env), session: env.session)
        return reply.map { (200..<300).contains($0.status) } ?? false
    }

    @MainActor
    static func deleteCommands(_ ids: [String], env: AssistantRegistration.Environment = .live) async {
        guard !ids.isEmpty else { return }
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        _ = await send(commandRequest("/command", method: "DELETE", query: query, env: env), session: env.session)
    }
}

extension AppModel {
    /// 명령을 차례로 반영한다. 데이터를 바꿀 수 없는 상태면 nil(서버에 그대로 둔다).
    /// 꺼 둔 종류는 거절하고, 반영한 것마다 되돌리기 정보를 남긴다(AIR1110A02).
    /// `journal`을 주면 명령 하나를 마칠 때마다 결과와 「AI가 한 일」을 적어, 도중에 꺼져도 잃지 않는다(REV1110A06).
    func applyAssistantCommands(
        _ batch: AssistantCommandBatch, defaults: UserDefaults = .standard, journal: AssistantCommandJournal? = nil
    ) async -> AssistantCommandOutcome? {
        guard acceptsDataMutation() else { return nil }
        let preferences: AssistantPreferenceStore = defaults === UserDefaults.standard ? .live : .test(defaults)
        var outcome = AssistantCommandOutcome()
        outcome.results = batch.invalidIDs.map { .init(id: $0, applied: false, reason: "invalid") }
        journal?.record(outcome.results)
        // 거절한 명령도 사유와 함께 「AI가 한 일」에 남긴다(AIP1114A05). 종류를 모르는 것은 남길 수 없다.
        journal?.log(batch.invalidIDs.compactMap { id in
            batch.invalidInfo[id].map {
                AssistantLogEntry.rejected(commandID: id, kind: $0.kind, reason: "invalid", keyID: $0.keyID, source: $0.source, taskID: $0.taskID, defaults: defaults)
            }
        })
        for command in batch.commands {
            let kind = command.action.kind
            guard AssistantActionToggles.isEnabled(kind, defaults: defaults) else {
                let refused = AssistantCommandOutcome.Result(id: command.id, applied: false, reason: "disabled")
                outcome.results.append(refused)
                journal?.record([refused])
                journal?.log([AssistantLogEntry.rejected(command, reason: "disabled", defaults: defaults)])
                continue
            }
            journal?.begin(command.id)
            let before = snapshot
            let result = await applyAssistantAction(command.action, preferences: preferences)
            let item = AssistantCommandOutcome.Result(id: command.id, applied: result.reason == nil, reason: result.reason)
            outcome.results.append(item)
            let entry = result.reason == nil ? assistantLogEntry(command, result: result, before: before, defaults: defaults) : nil
            if let entry {
                outcome.count(kind)
                outcome.entries.append(entry)
                // AI가 고친 메모는 「AI가 수정함」을 붙이고, 맡긴 다듬기 목록에서 뺀다(MEM1110A02).
                if case let .updateMemo(memoID, _) = command.action, let memo = assistantMemo(memoID) {
                    noteAssistantMemoEdit(memo.id, by: entry.connection)
                }
            }
            journal?.finish(item, entry: entry ?? result.reason.map { AssistantLogEntry.rejected(command, reason: $0, defaults: defaults) })
        }
        return outcome
    }

    private func assistantLogEntry(
        _ command: AssistantCommand, result: AssistantEditResult, before: TaptionDataSnapshot, defaults: UserDefaults
    ) -> AssistantLogEntry {
        var delta = AssistantEditDelta.difference(from: before, to: snapshot, actualIDs: result.actualIDs)
        if !result.preferences.isEmpty { delta.preferences = (delta.preferences ?? []) + result.preferences }
        delta.bubbleID = result.bubbleID
        delta.paymentRuleID = result.paymentRuleID
        delta.appChange = result.appChange
        delta.ledgerEntryID = result.ledgerEntryID
        delta.ledgerEntry = result.ledgerEntry
        delta.ledgerBefore = result.ledgerBefore
        delta.movement = result.movementBefore.map {
            AssistantMovementChange(before: $0, after: .init(snapshot, ids: Set($0.segments.map(\.id))))
        }
        return AssistantLogEntry(
            commandID: command.id, kind: command.action.kind, appliedAt: .now,
            before: result.before, after: result.after, delta: delta,
            keyID: command.keyID, connection: AssistantConnectionName.name(keyID: command.keyID, source: command.source, defaults: defaults),
            taskID: command.taskID
        )
    }
}

extension MapHomeView {
    /// 여행 계획 확인과 같은 때(앱을 열 때) 명령을 받아 반영하고 알림을 띄운다.
    /// 한 번에 기존 항목 20개를 넘게 바꾸면 반영하지 않고 확인 시트를 띄운다(AIR1110A02).
    func checkAssistantCommands() async {
        // 명령을 먼저 받아 바로 보이게 하고(SYN1111A01), 올리지 못한 다듬기 목록은 그 뒤에 다시 올린다(MEM1110A02).
        AssistantCommandRefresh.model = model
        await AssistantCommandRefresh.now(language: language)
        await MemoPolishQueue.upload()
    }
}

extension AssistantCommandLedger {
    static func forget(_ ids: [String], defaults: UserDefaults = .standard) {
        defaults.set(handled(defaults).filter { !ids.contains($0) }, forKey: defaultsKey)
    }
}
