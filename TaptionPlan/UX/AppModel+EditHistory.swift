import Foundation
import TaptionPlanCore

struct AppModelHistoryChange<Value: Hashable> {
    let id: UUID
    let before: Value?
    let after: Value?
}

struct AppModelHistoryEntry {
    let plans: [AppModelHistoryChange<PlanRecord>]
    let manualActuals: [AppModelHistoryChange<ActualRecord>]
    let corrections: [AppModelHistoryChange<ActivityCorrection>]
    let addedLabels: Set<String>
    let removedLabels: Set<String>
    let addedSleepSpans: Set<TimeSpan>
    let removedSleepSpans: Set<TimeSpan>
    let addedSuppressedIDs: Set<UUID>
    let removedSuppressedIDs: Set<UUID>

    var isEmpty: Bool {
        plans.isEmpty && manualActuals.isEmpty && corrections.isEmpty
            && addedLabels.isEmpty && removedLabels.isEmpty
            && addedSleepSpans.isEmpty && removedSleepSpans.isEmpty
            && addedSuppressedIDs.isEmpty && removedSuppressedIDs.isEmpty
    }

    static func difference(
        from before: TaptionDataSnapshot,
        to after: TaptionDataSnapshot
    ) -> Self {
        let planOrigins: (PlanRecord) -> Bool = {
            $0.origin == .user || $0.origin == .repeatRule
        }
        let manualRecords: (ActualRecord) -> Bool = { $0.source == .manual }
        let oldLabels = Set(before.settings.customActivityLabels)
        let newLabels = Set(after.settings.customActivityLabels)
        let oldSleepSpans = Set(before.settings.confirmedSleepSpans)
        let newSleepSpans = Set(after.settings.confirmedSleepSpans)

        return Self(
            plans: changes(
                from: before.plans,
                to: after.plans,
                id: \.id,
                include: planOrigins
            ),
            manualActuals: changes(
                from: before.actuals,
                to: after.actuals,
                id: \.id,
                include: manualRecords
            ),
            corrections: dictionaryChanges(
                from: before.settings.activityCorrections,
                to: after.settings.activityCorrections
            ),
            addedLabels: newLabels.subtracting(oldLabels),
            removedLabels: oldLabels.subtracting(newLabels),
            addedSleepSpans: newSleepSpans.subtracting(oldSleepSpans),
            removedSleepSpans: oldSleepSpans.subtracting(newSleepSpans),
            addedSuppressedIDs: after.settings.suppressedActualIDs
                .subtracting(before.settings.suppressedActualIDs),
            removedSuppressedIDs: before.settings.suppressedActualIDs
                .subtracting(after.settings.suppressedActualIDs)
        )
    }

    func applying(
        to source: TaptionDataSnapshot,
        undo: Bool
    ) -> TaptionDataSnapshot? {
        var result = source
        guard Self.apply(plans, to: &result.plans, id: \.id, undo: undo),
              Self.apply(
                manualActuals,
                to: &result.actuals,
                id: \.id,
                undo: undo
              ) else {
            return nil
        }

        for change in corrections {
            let expected = undo ? change.after : change.before
            guard result.settings.activityCorrections[change.id] == expected
            else { return nil }
        }
        for change in corrections {
            let replacement = undo ? change.before : change.after
            result.settings.activityCorrections[change.id] = replacement
        }

        let labelsToAdd = undo ? removedLabels : addedLabels
        let labelsToRemove = undo ? addedLabels : removedLabels
        result.settings.customActivityLabels = Self.applyingSetChanges(
            to: result.settings.customActivityLabels,
            adding: labelsToAdd,
            removing: labelsToRemove
        )

        let spansToAdd = undo ? removedSleepSpans : addedSleepSpans
        let spansToRemove = undo ? addedSleepSpans : removedSleepSpans
        result.settings.confirmedSleepSpans = Self.applyingSetChanges(
            to: result.settings.confirmedSleepSpans,
            adding: spansToAdd,
            removing: spansToRemove
        ).sorted { $0.start < $1.start }

        let suppressedToAdd = undo ? removedSuppressedIDs : addedSuppressedIDs
        let suppressedToRemove = undo ? addedSuppressedIDs : removedSuppressedIDs
        result.settings.suppressedActualIDs.formUnion(suppressedToAdd)
        result.settings.suppressedActualIDs.subtract(suppressedToRemove)
        if !corrections.isEmpty {
            result.actuals = ActivityCorrectionEngine.applying(
                result.settings.activityCorrections,
                to: result.actuals
            ).sorted { $0.startedAt < $1.startedAt }
        } else if !manualActuals.isEmpty {
            result.actuals.sort { $0.startedAt < $1.startedAt }
        }
        result.plans.sort { $0.span.start < $1.span.start }
        return result
    }

    func mergingPlanChanges(with next: Self) -> Self? {
        guard !plans.isEmpty,
              manualActuals.isEmpty, next.manualActuals.isEmpty,
              corrections.isEmpty, next.corrections.isEmpty,
              addedLabels.isEmpty, next.addedLabels.isEmpty,
              removedLabels.isEmpty, next.removedLabels.isEmpty,
              addedSleepSpans.isEmpty, next.addedSleepSpans.isEmpty,
              removedSleepSpans.isEmpty, next.removedSleepSpans.isEmpty,
              addedSuppressedIDs.isEmpty, next.addedSuppressedIDs.isEmpty,
              removedSuppressedIDs.isEmpty, next.removedSuppressedIDs.isEmpty,
              Set(plans.map(\.id)) == Set(next.plans.map(\.id)) else {
            return nil
        }
        let nextByID = Dictionary(next.plans.map {
            ($0.id, $0)
        }, uniquingKeysWith: { first, _ in first })
        let combined = plans.compactMap { first -> AppModelHistoryChange<PlanRecord>? in
            guard let latest = nextByID[first.id],
                  first.before != latest.after else { return nil }
            return AppModelHistoryChange(
                id: first.id,
                before: first.before,
                after: latest.after
            )
        }
        guard !combined.isEmpty else { return nil }
        return Self(
            plans: combined,
            manualActuals: [],
            corrections: [],
            addedLabels: [],
            removedLabels: [],
            addedSleepSpans: [],
            removedSleepSpans: [],
            addedSuppressedIDs: [],
            removedSuppressedIDs: []
        )
    }

    static func changes<Value: Hashable>(
        from before: [Value],
        to after: [Value],
        id: KeyPath<Value, UUID>,
        include: (Value) -> Bool
    ) -> [AppModelHistoryChange<Value>] {
        let oldByID = Dictionary(
            before.filter(include).map { ($0[keyPath: id], $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let newByID = Dictionary(
            after.filter(include).map { ($0[keyPath: id], $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return Set(oldByID.keys).union(newByID.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                let old = oldByID[id]
                let new = newByID[id]
                guard old != new else { return nil }
                return AppModelHistoryChange(id: id, before: old, after: new)
            }
    }

    private static func dictionaryChanges<Value: Hashable>(
        from before: [UUID: Value],
        to after: [UUID: Value]
    ) -> [AppModelHistoryChange<Value>] {
        Set(before.keys).union(after.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                let old = before[id]
                let new = after[id]
                guard old != new else { return nil }
                return AppModelHistoryChange(id: id, before: old, after: new)
            }
    }

    static func apply<Value: Hashable>(
        _ changes: [AppModelHistoryChange<Value>],
        to values: inout [Value],
        id: KeyPath<Value, UUID>,
        undo: Bool
    ) -> Bool {
        var currentByID: [UUID: Value] = [:]
        for value in values {
            currentByID[value[keyPath: id]] = value
        }
        for change in changes {
            let expected = undo ? change.after : change.before
            guard currentByID[change.id] == expected else { return false }
        }
        for change in changes {
            let replacement = undo ? change.before : change.after
            if let index = values.firstIndex(where: {
                $0[keyPath: id] == change.id
            }) {
                if let replacement {
                    values[index] = replacement
                } else {
                    values.remove(at: index)
                }
            } else if let replacement {
                values.append(replacement)
            }
        }
        return true
    }

    private static func applyingSetChanges<Value: Hashable>(
        to values: [Value],
        adding: Set<Value>,
        removing: Set<Value>
    ) -> [Value] {
        var result = values.filter { !removing.contains($0) }
        for value in adding where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}

struct AppModelHistoryItem {
    let id = UUID()
    let entry: AppModelHistoryEntry
    let coalescingKey: String?
    var recordedAt: Date
}

extension AppModel {
    func undoLastUserEdit() {
        guard let item = userEditUndoHistory.last else { return }
        guard let restored = item.entry.applying(to: snapshot, undo: true) else {
            userEditUndoHistory.removeLast()
            synchronizeUserEditHistoryAvailability()
            userFacingError = AppLanguagePreference.text(
                korean: "동기화된 변경과 충돌해 실행취소하지 못했습니다.",
                english: "Undo failed because it conflicts with synced changes."
            )
            return
        }
        guard restored != snapshot else { return }
        snapshot = restored
        userEditUndoHistory.removeLast()
        userEditRedoHistory.append(item)
        synchronizeUserEditHistoryAvailability()
        Task { await persist() }
    }

    func redoLastUserEdit() {
        guard let item = userEditRedoHistory.last else { return }
        guard let reapplied = item.entry.applying(to: snapshot, undo: false) else {
            userEditRedoHistory.removeLast()
            synchronizeUserEditHistoryAvailability()
            userFacingError = AppLanguagePreference.text(
                korean: "동기화된 변경과 충돌해 다시실행하지 못했습니다.",
                english: "Redo failed because it conflicts with synced changes."
            )
            return
        }
        guard reapplied != snapshot else { return }
        snapshot = reapplied
        userEditRedoHistory.removeLast()
        userEditUndoHistory.append(item)
        synchronizeUserEditHistoryAvailability()
        Task { await persist() }
    }

    func recordUserEdit(
        from before: TaptionDataSnapshot,
        coalescingKey: String? = nil
    ) {
        let entry = AppModelHistoryEntry.difference(from: before, to: snapshot)
        guard !entry.isEmpty else { return }
        let now = Date.now
        if let coalescingKey,
           let previous = userEditUndoHistory.last,
           previous.coalescingKey == coalescingKey,
           now.timeIntervalSince(previous.recordedAt) <= 1.2 {
            userEditUndoHistory.removeLast()
            if let merged = previous.entry.mergingPlanChanges(with: entry) {
                userEditUndoHistory.append(
                    AppModelHistoryItem(
                        entry: merged,
                        coalescingKey: coalescingKey,
                        recordedAt: now
                    )
                )
            }
            userEditRedoHistory.removeAll()
            synchronizeUserEditHistoryAvailability()
            return
        }
        userEditUndoHistory.append(
            AppModelHistoryItem(
                entry: entry,
                coalescingKey: coalescingKey,
                recordedAt: now
            )
        )
        if userEditUndoHistory.count > 40 {
            userEditUndoHistory.removeFirst(
                userEditUndoHistory.count - 40
            )
        }
        userEditRedoHistory.removeAll()
        synchronizeUserEditHistoryAvailability()
    }

    func clearUserEditRedoHistory() {
        guard !userEditRedoHistory.isEmpty else { return }
        userEditRedoHistory.removeAll()
        synchronizeUserEditHistoryAvailability()
    }

    func synchronizeUserEditHistoryAvailability() {
        canUndo = !userEditUndoHistory.isEmpty
        canRedo = !userEditRedoHistory.isEmpty
    }
}
