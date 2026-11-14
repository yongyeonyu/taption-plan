import Foundation
import TaptionPlanCore

/// AI 명령 하나가 바꾼 값의 전·후(AIR1110A02). 「AI가 한 일」에서 되돌릴 때 쓴다.
/// 기록은 교정표·사용자 덮개 기록·표시 사본만 담고, 센서 원본은 담지도 고치지도 않는다.
struct AssistantEditDelta: Codable, Equatable, Sendable {
    struct Change<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var id: UUID
        var before: Value?
        var after: Value?
    }

    var plans: [Change<PlanRecord>] = []
    var memos: [Change<ActionMemo>] = []
    var actuals: [Change<ActualRecord>] = []
    var corrections: [Change<ActivityCorrection>] = []
    var addedSleepSpans: [TimeSpan] = []
    var removedSleepSpans: [TimeSpan] = []
    /// 여행 핀·일정 목록 전·후(AIR1110A03). 예전 기록에는 없다.
    var travel: AssistantTravelChange?
    /// 지도 스타일·언어·표시 켜기 같은 설정 전·후(AIR1110A03). 예전 기록에는 없다.
    var preferences: [AssistantPreferenceChange]?
    /// AI 말풍선(BUB1110A01). 예전 기록에는 없다.
    var bubbleID: UUID?
    /// 가계부 기록(LED1110A01). 예전 기록에는 없다.
    var ledgerEntryID: UUID?
    /// 더할 때의 기록. 그 뒤 사용자가 고쳤으면 되돌리지 않는다.
    var ledgerEntry: LedgerEntry?
    /// 고치거나 지우기 전 기록(AIQ1111A01). 있으면 되돌릴 때 지우지 않고 이것으로 돌린다.
    var ledgerBefore: LedgerEntry?
    /// 이동 수단 교정 전·후(ACT1111A01). 예전 기록에는 없다.
    var movement: AssistantMovementChange?
    /// 결제 문자 읽기 규칙(PRL1112A01). 예전 기록에는 없다.
    var paymentRuleID: UUID?
    /// 가계부 설정·정리·화면 열기(ACX1112A01). 예전 기록에는 없다.
    var appChange: AssistantAppChange?
    /// 자주 가는 장소·분류 목록 전·후(ACA1112A01). 예전 기록에는 없다.
    var places: ListChange<FrequentPlace>?
    var categories: ListChange<CategoryDefinition>?
    /// 여행 목록 전·후(ACB1112A01). 일정·핀은 `travel`이, 일상 쪽 계획은 `plans`가 담는다.
    var trips: ListChange<TravelTrip>?
    /// 탑승 확인·거절 목록 전·후와, 지우면서 「다시 만들지 않기」로 적은 기록(ACT1114A07). 예전 기록에는 없다.
    var boardingDecisions: ListChange<TransitBoardingDecision>?
    var suppressedActualIDs: [UUID]?

    struct ListChange<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var before: [Value]
        var after: [Value]
    }

    var isEmpty: Bool {
        plans.isEmpty && memos.isEmpty && actuals.isEmpty && corrections.isEmpty
            && addedSleepSpans.isEmpty && removedSleepSpans.isEmpty && travel == nil && (preferences ?? []).isEmpty && movement == nil
            && places == nil && categories == nil && trips == nil && boardingDecisions == nil
    }

    /// 기록은 명령이 고른 id와 새로 생기거나 사라진 수동 기록만 본다. 그 사이 센서 갱신이 바꾼 자동 기록은 담지 않는다.
    static func difference(from before: TaptionDataSnapshot, to after: TaptionDataSnapshot, actualIDs: Set<UUID>) -> Self {
        let oldActuals = Dictionary(before.actuals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newActuals = Dictionary(after.actuals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let manualChurn = Set(oldActuals.keys).symmetricDifference(newActuals.keys).filter {
            (oldActuals[$0] ?? newActuals[$0])?.source == .manual
        }
        let oldSleep = Set(before.settings.confirmedSleepSpans), newSleep = Set(after.settings.confirmedSleepSpans)
        let oldTravel = AssistantTravelState(before.settings), newTravel = AssistantTravelState(after.settings)
        let style = before.settings.mapDisplayStyle == after.settings.mapDisplayStyle ? nil : AssistantPreferenceChange(
            key: AssistantPreferenceChange.mapStyleKey,
            before: before.settings.mapDisplayStyle.rawValue, after: after.settings.mapDisplayStyle.rawValue
        )
        return Self(
            plans: changes(before.plans, after.plans),
            memos: changes(before.memos, after.memos),
            actuals: actualIDs.union(manualChurn).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
                oldActuals[id] == newActuals[id] ? nil : Change(id: id, before: oldActuals[id], after: newActuals[id])
            },
            corrections: Set(before.settings.activityCorrections.keys).union(after.settings.activityCorrections.keys)
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { id in
                    let old = before.settings.activityCorrections[id], new = after.settings.activityCorrections[id]
                    return old == new ? nil : Change(id: id, before: old, after: new)
                },
            addedSleepSpans: newSleep.subtracting(oldSleep).sorted { $0.start < $1.start },
            removedSleepSpans: oldSleep.subtracting(newSleep).sorted { $0.start < $1.start },
            travel: oldTravel == newTravel ? nil : AssistantTravelChange(before: oldTravel, after: newTravel),
            preferences: style.map { [$0] },
            places: before.settings.frequentPlaces == after.settings.frequentPlaces
                ? nil : ListChange(before: before.settings.frequentPlaces, after: after.settings.frequentPlaces),
            categories: before.categories == after.categories ? nil : ListChange(before: before.categories, after: after.categories),
            trips: before.settings.travelTrips == after.settings.travelTrips
                ? nil : ListChange(before: before.settings.travelTrips ?? [], after: after.settings.travelTrips ?? []),
            boardingDecisions: before.settings.transitBoardingDecisions == after.settings.transitBoardingDecisions
                ? nil : ListChange(before: before.settings.transitBoardingDecisions, after: after.settings.transitBoardingDecisions)
        )
    }

    private static func changes<Value: Identifiable & Codable & Equatable & Sendable>(
        _ before: [Value], _ after: [Value]
    ) -> [Change<Value>] where Value.ID == UUID {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(old.keys).union(new.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            old[id] == new[id] ? nil : Change(id: id, before: old[id], after: new[id])
        }
    }

    /// 거꾸로 적용한 값. 그 뒤 사용자나 동기화가 같은 일정·메모·교정을 바꿨으면 nil.
    /// 지운 일정·메모는 iCloud 삭제 표시와 부딪히지 않게 새 id로 다시 만든다.
    func undoing(in snapshot: TaptionDataSnapshot, newID: () -> UUID = UUID.init) -> TaptionDataSnapshot? {
        var result = snapshot
        let plansByID = Dictionary(result.plans.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let memosByID = Dictionary(result.memos.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for change in plans where change.after != nil && plansByID[change.id] != change.after { return nil }
        for change in memos where change.after != nil && memosByID[change.id] != change.after { return nil }
        for change in corrections where result.settings.activityCorrections[change.id] != change.after { return nil }
        if let travel, AssistantTravelState(result.settings) != travel.after { return nil }
        let style = (preferences ?? []).first { $0.key == AssistantPreferenceChange.mapStyleKey }
        if let style, result.settings.mapDisplayStyle.rawValue != style.after { return nil }
        let actualsByID = Dictionary(result.actuals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for change in actuals where Self.blocksUndo(change, current: actualsByID[change.id]) { return nil }
        // 이동 수단은 그 뒤 사용자나 센서가 같은 구간·교정표를 바꿨으면 되돌리지 않는다.
        if let movement, AssistantMovementChange.State(result, ids: Set(movement.after.segments.map(\.id))) != movement.after { return nil }

        // 장소·분류는 그 뒤 목록이 바뀌었으면 되돌리지 않는다.
        if let places, result.settings.frequentPlaces != places.after { return nil }
        if let categories, result.categories != categories.after { return nil }
        if let trips, (result.settings.travelTrips ?? []) != trips.after { return nil }
        if let boardingDecisions {
            guard result.settings.transitBoardingDecisions == boardingDecisions.after else { return nil }
            result.settings.transitBoardingDecisions = boardingDecisions.before
        }
        if let suppressedActualIDs { result.settings.suppressedActualIDs.subtract(suppressedActualIDs) }
        if let trips { result.settings.travelTrips = trips.before.isEmpty ? nil : trips.before }
        if let places { result.settings.frequentPlaces = places.before }
        if let categories { result.categories = categories.before }

        var renamed: [UUID: UUID] = [:]
        for change in plans {
            result.plans.removeAll { $0.id == change.id }
            guard var restored = change.before else { continue }
            if change.after == nil {
                restored.id = newID()
                renamed[change.id] = restored.id
            }
            result.plans.append(restored)
        }
        for change in memos {
            result.memos.removeAll { $0.id == change.id }
            guard var restored = change.before else { continue }
            if change.after == nil { restored.id = newID() }
            if let planID = restored.planID, let renamedID = renamed[planID] { restored.planID = renamedID }
            result.memos.append(restored)
        }
        // 지운 상위 루틴을 새 id로 되살렸으면 하위 일정·기록 연결도 새 id로 잇는다(AIR1110A03).
        if !renamed.isEmpty {
            for index in result.plans.indices {
                if let parentID = result.plans[index].parentID, let renamedID = renamed[parentID] { result.plans[index].parentID = renamedID }
            }
        }
        for change in corrections { result.settings.activityCorrections[change.id] = change.before }
        if let movement {
            for segment in movement.before.segments {
                if let index = result.travel.firstIndex(where: { $0.id == segment.id }) { result.travel[index] = segment }
            }
            result.settings.movementCorrections = movement.before.corrections
        }
        if let travel { travel.before.apply(to: &result.settings, renamed: renamed) }
        if let style, let raw = style.before, let value = MapDisplayStyle(rawValue: raw) { result.settings.mapDisplayStyle = value }
        // 기록은 AI가 바꾼 칸만 예전 값으로 돌린다. 그 뒤 센서가 고친 자동 기록 위에 옛 사본을 덮어쓰지 않는다(REV1110A06).
        for change in actuals {
            let current = actualsByID[change.id]
            result.actuals.removeAll { $0.id == change.id }
            guard var restored = Self.restoredActual(change, current: current) else { continue }
            if let planID = restored.planID, let renamedID = renamed[planID] { restored.planID = renamedID }
            if let routineID = restored.routineID, let renamedID = renamed[routineID] { restored.routineID = renamedID }
            result.actuals.append(restored)
        }
        var sleep = result.settings.confirmedSleepSpans.filter { !addedSleepSpans.contains($0) }
        for span in removedSleepSpans where !sleep.contains(span) { sleep.append(span) }
        result.settings.confirmedSleepSpans = sleep.sorted { $0.start < $1.start }
        result.actuals = ActivityCorrectionEngine.applying(result.settings.activityCorrections, to: result.actuals)
            .sorted { $0.startedAt < $1.startedAt }
        result.plans.sort { $0.span.start < $1.span.start }
        return result
    }
}

/// 기록 되돌리기 규칙(REV1110A06). 사용자가 만든 기록은 일정·메모처럼 그 뒤 바뀌었으면 되돌리지 않고,
/// 자동 기록은 센서가 계속 고치므로 AI가 바꾼 칸만 되돌린다.
extension AssistantEditDelta {
    static func blocksUndo(_ change: Change<ActualRecord>, current: ActualRecord?) -> Bool {
        guard (change.after ?? change.before)?.source == .manual else { return false }
        return change.after != nil && current != change.after
    }

    /// 되돌린 뒤 그 자리에 둘 기록. nil이면 두지 않는다.
    static func restoredActual(_ change: Change<ActualRecord>, current: ActualRecord?) -> ActualRecord? {
        guard let before = change.before else { return nil }
        // AI가 지운(연결이 끊겨 사라진) 기록은 센서가 이미 다시 만들었으면 지금 것을 둔다.
        guard let after = change.after else { return current ?? before }
        guard var merged = current else { return nil }
        if merged == after { return before }
        func revert<Value: Equatable>(_ path: WritableKeyPath<ActualRecord, Value>) {
            if before[keyPath: path] != after[keyPath: path], merged[keyPath: path] == after[keyPath: path] {
                merged[keyPath: path] = before[keyPath: path]
            }
        }
        revert(\.title)
        revert(\.categoryID)
        revert(\.behavior)
        revert(\.startedAt)
        revert(\.endedAt)
        revert(\.planID)
        revert(\.routineID)
        revert(\.manuallyCorrected)
        return merged
    }
}

/// 「AI가 한 일」 한 줄.
struct AssistantLogEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var commandID: String
    var kind: AssistantActionKind
    var appliedAt: Date
    var before: String
    var after: String
    var delta: AssistantEditDelta
    var undoneAt: Date?
    /// 명령을 보낸 연결 키 id와 그때의 연결 이름(SEC1110A02). 예전 기록에는 없다.
    var keyID: String?
    var connection: String?
    /// 이 명령이 딸린 맡긴 일의 id(AIP1114A05). 예전 기록에는 없다.
    var taskID: String?
    /// 반영하지 못한 명령이면 그 사유. 바뀐 것이 없어 되돌릴 수 없다. 예전 기록에는 없다.
    var rejectedReason: String?

    var isRejected: Bool { rejectedReason != nil }
    /// 되돌리기를 눌러 볼 수 있는 항목.
    var canUndo: Bool { rejectedReason == nil && undoneAt == nil }
}

extension AssistantLogEntry {
    /// 거절한 명령의 기록. 바뀐 값이 없다.
    @MainActor
    static func rejected(
        commandID: String, kind: AssistantActionKind, reason: String, keyID: String?, source: String?, taskID: String?,
        at date: Date = .now, defaults: UserDefaults
    ) -> Self {
        Self(
            commandID: commandID, kind: kind, appliedAt: date, before: "", after: "", delta: .init(),
            keyID: keyID, connection: AssistantConnectionName.name(keyID: keyID, source: source, defaults: defaults),
            taskID: taskID, rejectedReason: reason
        )
    }

    @MainActor
    static func rejected(_ command: AssistantCommand, reason: String, defaults: UserDefaults) -> Self {
        rejected(commandID: command.id, kind: command.action.kind, reason: reason, keyID: command.keyID, source: command.source, taskID: command.taskID, defaults: defaults)
    }
}

/// 거절 사유를 사람이 읽는 짧은 글로(AIP1114A05). 사유 낱말은 앱이 명령 결과에 쓰는 그대로다.
enum AssistantRejection {
    static func message(_ reason: String, language: MapHomeLanguage) -> String {
        switch reason {
        case "disabled": language.text("꺼 둔 종류라 하지 않았어요", "This kind of edit is switched off")
        case "invalid", "invalid_time", "invalid_category", "end_before_start", "no_dates":
            language.text("요청 형식이 맞지 않았어요", "The request wasn't valid")
        case "edit_failed", "memo_failed", "schedule_failed", "goal_failed", "trip_failed":
            language.text("앱에서 저장하지 못했어요", "The app couldn't save it")
        case "no_change": language.text("바꿀 것이 없었어요", "There was nothing to change")
        case "duplicate": language.text("이미 있는 내용이에요", "It was already there")
        case "unknown_category": language.text("없는 분류예요", "That category doesn't exist")
        case _ where reason.hasPrefix("no_"): language.text("고칠 대상을 찾지 못했어요", "Couldn't find the item to change")
        default: language.text("반영하지 못했어요 (\(reason))", "Not applied (\(reason))")
        }
    }
}

/// 맡긴 일 하나에 딸린 「AI가 한 일」 찾기와 한꺼번에 되돌리기(AIP1114A05).
enum AssistantTaskEdits {
    /// 명령에 붙은 일 id가 같거나, AI가 일을 끝내며 적은 명령 id에 드는 항목.
    static func entries(for task: AITaskQueue.Task, in log: [AssistantLogEntry]) -> [AssistantLogEntry] {
        let commandIDs = Set(task.outcome?.commandIds ?? [])
        return log.filter { $0.taskID == task.id || commandIDs.contains($0.commandID) }
    }

    /// 되돌릴 수 있는 것을 최근 것부터 되돌린다. 되돌린 수와 못 되돌린 수를 준다.
    @MainActor
    static func undo(_ entries: [AssistantLogEntry], model: AppModel) async -> (undone: Int, failed: Int) {
        var undone = 0, failed = 0
        for entry in entries.filter(\.canUndo).sorted(by: { $0.appliedAt > $1.appliedAt }) {
            if await model.undoAssistantEntry(entry) {
                AssistantActionLog.markUndone(entry.id)
                undone += 1
            } else {
                failed += 1
            }
        }
        return (undone, failed)
    }
}

/// AI가 고친 이동 구간과 수단 교정표의 전·후(ACT1111A01). 구간은 명령이 고른 것만 담는다.
struct AssistantMovementChange: Codable, Equatable, Sendable {
    struct State: Codable, Equatable, Sendable {
        var segments: [TravelSegment]
        var corrections: [TravelModeCorrection]

        init(_ snapshot: TaptionDataSnapshot, ids: Set<UUID>) {
            segments = snapshot.travel.filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
            corrections = snapshot.settings.movementCorrections
        }
    }

    var before: State
    var after: State
}

/// 최근 200개를 앱 Application Support의 파일 하나에 둔다. 메모 글이 들어 있어 기기 밖으로 보내지 않는다.
@MainActor
enum AssistantActionLog {
    static let limit = 200

    static var url: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TaptionPlan/Assistant", isDirectory: true).appendingPathComponent("assistant-log.json")
    }

    static func load(from file: URL = url) -> [AssistantLogEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([AssistantLogEntry].self, from: data)) ?? []
    }

    /// 새 항목을 앞에 붙이고 오래된 것을 버린다.
    static func append(_ entries: [AssistantLogEntry], to file: URL = url) {
        guard !entries.isEmpty else { return }
        save(Array((entries.reversed() + load(from: file)).prefix(limit)), to: file)
    }

    static func save(_ entries: [AssistantLogEntry], to file: URL = url) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 백그라운드 작업도 읽고 써야 해서 첫 잠금 해제 뒤 보호를 쓴다.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func markUndone(_ id: UUID, at date: Date = .now, file: URL = url) {
        var entries = load(from: file)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].undoneAt = date
        save(entries, to: file)
    }

    static func clear(file: URL = url) { try? FileManager.default.removeItem(at: file) }
}

extension AppModel {
    /// 「AI가 한 일」의 되돌리기. 거꾸로 적용한 값을 저장하고, 실패하면 편집 전으로 돌린다.
    func undoAssistantEntry(_ entry: AssistantLogEntry, preferences: AssistantPreferenceStore = .live) async -> Bool {
        guard acceptsDataMutation(), entry.canUndo else { return false }
        if let added = entry.delta.ledgerEntry {
            await preferences.ledger.load()
            if let current = preferences.ledger.entries.first(where: { $0.id == added.id }), current != added {
                userFacingError = AppLanguagePreference.text(
                    korean: "그 뒤에 바뀐 내용이 있어 되돌리지 못했어요. 앱에서 직접 고쳐 주세요.",
                    english: "It changed afterwards, so it couldn't be undone. Please edit it in the app."
                )
                return false
            }
        }
        let stored = (entry.delta.preferences ?? []).filter { $0.key != AssistantPreferenceChange.mapStyleKey }
        let storeChangeIsCurrent = await entry.delta.appChange?.isCurrent(preferences) ?? true
        let appChangeIsCurrent = storeChangeIsCurrent && assistantPromptChangeIsCurrent(entry.delta.appChange)
        guard appChangeIsCurrent, stored.allSatisfy({ preferences.value($0.key, model: self) == $0.after }), let restored = entry.delta.undoing(in: snapshot) else {
            userFacingError = AppLanguagePreference.text(
                korean: "그 뒤에 바뀐 내용이 있어 되돌리지 못했어요. 앱에서 직접 고쳐 주세요.",
                english: "It changed afterwards, so it couldn't be undone. Please edit it in the app."
            )
            return false
        }
        let previous = snapshot
        snapshot = restored
        let lastID = userEditUndoHistory.last?.id
        recordUserEdit(from: previous, includesAutomaticActuals: true)
        let addedID = userEditUndoHistory.last?.id != lastID ? userEditUndoHistory.last?.id : nil
        guard await persistOrRollBack(userEditRollback(from: previous, historyItemID: addedID)) else { return false }
        for change in stored { preferences.set(change.key, value: change.before, model: self) }
        // 되돌린 메모의 금액대로 가계부도 맞춘다(AI가 고친 메모를 되돌리면 금액도 돌아온다).
        resyncMemoLedger(changed: Set(entry.delta.memos.map(\.id)).subtracting([entry.delta.ledgerEntry?.memoID].compactMap { $0 }))
        if let bubbleID = entry.delta.bubbleID { AssistantBubbleStore.remove(bubbleID, file: preferences.bubbleFile) }
        // 규칙만 지운다. 그 규칙으로 다시 읽어 넣은 가계부 기록은 그대로 둔다(PRL1112A01).
        if let ruleID = entry.delta.paymentRuleID { LedgerMessageRules.remove(ruleID, defaults: preferences.defaults) }
        if let before = entry.delta.ledgerBefore {
            await preferences.ledger.save(before)
        } else if let ledgerID = entry.delta.ledgerEntryID {
            await preferences.ledger.delete(ledgerID)
        }
        // 여행 기록이 돌아갔으면 그 여행의 정산 짝 기록도 다시 맞춘다(ACT1114A07).
        for tripID in Set([entry.delta.ledgerBefore?.tripID, entry.delta.ledgerEntry?.tripID].compactMap { $0 }) { await preferences.ledger.syncTrip(tripID) }
        await entry.delta.appChange?.undo(preferences)
        await undoAssistantPromptChange(entry.delta.appChange)
        return true
    }
}
