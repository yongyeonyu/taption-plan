import Foundation
@_exported import TaptionAssistantProtocol
import TaptionPlanCore

extension AssistantCommandParser {
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
        // RMN1114A22: addSchedule·updateSchedule의 장소(이름+좌표)·예상 지출·장소 지우기.
        let placeName: String?, plannedSpend: Double?, clearPlace: Bool?
    }

    /// `{"commands":[...]}`를 읽는다. 서버와 같은 규칙으로 다시 본다.
    static func parse(_ data: Data, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> AssistantCommandBatch? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var batch = AssistantCommandBatch(commands: [], invalidIDs: [])
        for item in envelope.commands {
            guard let id = item.id, !id.isEmpty, !id.contains(",") else { continue }
            if let fields = item.values.map({ AssistantFields(values: $0, now: now, calendar: calendar) }),
               let name = fields.name, AssistantOperations.spec(name) != nil {
                let keyID = fields.string("keyId", max: 64), source = fields.string("source", max: 16), taskID = fields.string("taskId", max: 100)
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
            guard let memoID = clean(raw.memoId, max: 100), let when = AssistantWhenChange(date: raw.date, time: raw.time, calendar: calendar) else { return nil }
            if raw.text != nil, clean(raw.text, max: 2_000) == nil { return nil }
            guard raw.text != nil || !when.isEmpty else { return nil }
            return .updateMemo(memoID: memoID, text: clean(raw.text, max: 2_000), when: when)
        case "deleteMemo":
            return clean(raw.memoId, max: 100).map { .deleteMemo(memoID: $0) }
        default:
            return dataAction(raw, day: day, calendar: calendar)
        }
    }

    /// 일정의 분류·중요·상위 루틴(ACT1114A07)과 장소·예상 지출(RMN1114A22). 틀린 칸이 있으면 nil. `parentGoalId` "none"은 고칠 때만 받는다.
    private static func scheduleExtras(_ raw: Raw, allowsDetach: Bool) -> AssistantScheduleExtras? {
        if raw.categoryId != nil, clean(raw.categoryId, max: 100) == nil { return nil }
        var parent: String?
        if let text = raw.parentGoalId {
            if allowsDetach, text == "none" { parent = "" } else if UUID(uuidString: text) != nil { parent = text } else { return nil }
        }
        var extras = AssistantScheduleExtras(categoryID: clean(raw.categoryId, max: 100), important: raw.important, parentGoalID: parent)
        // RMN1114A22: 장소는 `latitude`·`longitude`만 받는다(`lat`·`lng`는 여행 핀의 옛 이름). 장소 지우기는 고칠 때만.
        guard extras.readSpot(
            placeName: raw.placeName, latitude: raw.latitude, longitude: raw.longitude,
            plannedSpend: raw.plannedSpend, clearPlace: raw.clearPlace, allowsClear: allowsDetach
        ) else { return nil }
        return extras
    }

    /// `planId`, 없으면 `date`+`startTime`으로 일정을 고른다.
    private static func planTarget(_ raw: Raw, day: Date?, calendar: Calendar) -> AssistantPlanTarget? {
        if let planID = clean(raw.planId, max: 100) { return AssistantPlanTarget(planID: planID, startTime: nil) }
        guard let day, let time = raw.startTime, let startTime = clock(time, on: day, calendar: calendar) else { return nil }
        return AssistantPlanTarget(planID: nil, startTime: startTime)
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
    typealias Result = AssistantCommandResult

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
    static func fetchCommands(env: AssistantRegistration.Environment = .live) async -> AssistantCommandBatch? {
        // 화면에서 기다리는 요청이라 5초 안에 끝낸다(SYN1111A01).
        guard let (response, data) = await sendResponse(commandRequest("/command", method: "GET", env: env, timeout: commandFetchTimeout), session: env.session)
        else { return nil }
        // AI가 대화 중인지 알려 주는 머리 값으로 다음 확인 간격을 정한다(SYN1111A03).
        if let signal = AssistantCommandPolling.signal(from: response) { AssistantCommandPolling.signal = signal }
        if response.statusCode == 204 { return AssistantCommandBatch(commands: [], invalidIDs: []) }
        return response.statusCode == 200 ? AssistantCommandParser.parse(data) : nil
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
                if case let .updateMemo(memoID, text, _) = command.action, text != nil, let memo = assistantMemo(memoID) {
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
        if !result.suppressedActualIDs.isEmpty { delta.suppressedActualIDs = result.suppressedActualIDs.sorted { $0.uuidString < $1.uuidString } }
        delta.movement = result.movementBefore.map {
            AssistantMovementChange(before: $0, after: .init(snapshot, ids: Set($0.segments.map(\.id))))
        }
        return AssistantLogEntry(
            commandID: command.id, kind: command.action.kind, appliedAt: .now,
            before: result.before, after: result.after, delta: delta,
            keyID: command.keyID, connection: AssistantConnectionName.name(keyID: command.keyID, source: command.source, defaults: defaults),
            taskID: command.taskID, irreversible: result.cannotUndo ? true : nil
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

