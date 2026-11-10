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

    var isEmpty: Bool {
        plans.isEmpty && memos.isEmpty && actuals.isEmpty && corrections.isEmpty
            && addedSleepSpans.isEmpty && removedSleepSpans.isEmpty && travel == nil && (preferences ?? []).isEmpty
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
            preferences: style.map { [$0] }
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
        guard acceptsDataMutation(), entry.undoneAt == nil else { return false }
        let stored = (entry.delta.preferences ?? []).filter { $0.key != AssistantPreferenceChange.mapStyleKey }
        guard stored.allSatisfy({ preferences.value($0.key) == $0.after }), let restored = entry.delta.undoing(in: snapshot) else {
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
        if let bubbleID = entry.delta.bubbleID { AssistantBubbleStore.remove(bubbleID, file: preferences.bubbleFile) }
        if let ledgerID = entry.delta.ledgerEntryID { await preferences.ledger.delete(ledgerID) }
        return true
    }
}
