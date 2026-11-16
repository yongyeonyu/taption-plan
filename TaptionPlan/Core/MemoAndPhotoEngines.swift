import Foundation
import TaptionPlanCore

enum ActionMemoEditingEngine {
    static func updating(
        _ memo: ActionMemo,
        text: String,
        kind: MemoKind,
        at date: Date = .now
    ) -> ActionMemo? {
        let cleanText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanText.isEmpty else { return nil }
        var value = memo
        value.text = cleanText
        value.kind = kind
        value.updatedAt = date
        return value
    }
}

enum MapMemoDisplayFilterEngine {
    static func visibleMemos(
        _ memos: [ActionMemo],
        filter: MapMemoDisplayFilter,
        selectedPlanIDs: Set<UUID>,
        selectedTargetIDs: Set<String>
    ) -> [ActionMemo] {
        let mapped = memos.filter { $0.mapPoint != nil }
        guard filter == .relevant else { return mapped }

        return mapped.filter { memo in
            if let planID = memo.planID, selectedPlanIDs.contains(planID) {
                return true
            }
            if let targetID = memo.targetID,
               selectedTargetIDs.contains(targetID) {
                return true
            }
            return false
        }
    }

    static func visibleMemos(
        _ memos: [ActionMemo],
        on date: Date,
        filter: MapMemoDisplayFilter,
        selectedPlanIDs: Set<UUID>,
        selectedTargetIDs: Set<String>,
        calendar: Calendar = .autoupdatingCurrent,
        through: Date? = nil
    ) -> [ActionMemo] {
        visibleMemos(
            memos,
            filter: filter,
            selectedPlanIDs: selectedPlanIDs,
            selectedTargetIDs: selectedTargetIDs
        ).filter {
            guard calendar.isDate($0.occurredAt, inSameDayAs: date) else {
                return false
            }
            guard let through else { return true }
            return $0.occurredAt <= through
        }
    }
}

enum MapMemoLinkEngine {
    static func plan(
        containing date: Date,
        in plans: [PlanRecord]
    ) -> PlanRecord? {
        plans
            .filter { $0.span.start <= date && date < $0.span.end }
            .sorted {
                if $0.span.duration != $1.span.duration {
                    return $0.span.duration < $1.span.duration
                }
                return $0.createdAt < $1.createdAt
            }
            .first
    }
}

enum MapStickerDisplayFilterEngine {
    static func visibleMapStickers(
        _ stickers: [MapSticker],
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapSticker] {
        stickers.filter {
            $0.placement == .map
                && $0.point != nil
                && calendar.isDate($0.occurredAt, inSameDayAs: date)
        }
    }
}

/// A memo used to need a host plan, so a note left on a category row created a
/// one-minute placeholder titled `메모 - <카테고리>`. Those placeholders then
/// showed up in the 기록 탭 계획 카드 as plans the user never made. This lifts
/// their notes into standalone memos and removes only the placeholders.
enum MemoShellPlanMigration {
    static let titlePrefix = "메모 - "
    private static let shellDuration: TimeInterval = 60

    /// Deliberately strict: every condition is something the placeholder
    /// factory always produced. A plan that fails even one of them is a plan
    /// the user could have made by hand, so it is left alone.
    static func isShell(
        _ plan: PlanRecord,
        actuals: [ActualRecord],
        recordLinks: [RecordLink]
    ) -> Bool {
        let referencedRecordIDs = Set(actuals.flatMap {
            [$0.planID, $0.routineID].compactMap { $0 }
        })
        let referencedNodeIDs = Set(recordLinks.flatMap {
            [$0.fromNodeID, $0.toNodeID]
        })
        return isShell(
            plan,
            referencedRecordIDs: referencedRecordIDs,
            referencedNodeIDs: referencedNodeIDs
        )
    }

    private static func isShell(
        _ plan: PlanRecord,
        referencedRecordIDs: Set<UUID>,
        referencedNodeIDs: Set<String>
    ) -> Bool {
        guard plan.title.hasPrefix(titlePrefix),
              plan.title.count > titlePrefix.count,
              abs(plan.span.duration - shellDuration) < 0.5,
              plan.parentID == nil,
              plan.status == .planned,
              plan.origin == .user,
              !plan.isFixed,
              !plan.isImportant,
              plan.middleCategoryName == nil,
              plan.subCategoryName == nil,
              plan.repeatRules == nil,
              plan.externalCalendarID == nil,
              plan.externalEventID == nil else {
            return false
        }
        // A placeholder was never started, completed or linked to anything.
        guard !referencedRecordIDs.contains(plan.id) else {
            return false
        }
        return !referencedNodeIDs.contains("action.\(plan.id.uuidString)")
            && !referencedNodeIDs.contains("routine.\(plan.id.uuidString)")
    }

    /// Idempotent: once the placeholders are gone a second run finds nothing.
    static func apply(to snapshot: inout TaptionDataSnapshot) {
        apply(to: &snapshot, cancellationCheck: {})
    }

    static func apply(
        to snapshot: inout TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        var referencedRecordIDs = Set<UUID>()
        referencedRecordIDs.reserveCapacity(snapshot.actuals.count)
        for (index, actual) in snapshot.actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if let planID = actual.planID {
                referencedRecordIDs.insert(planID)
            }
            if let routineID = actual.routineID {
                referencedRecordIDs.insert(routineID)
            }
        }

        try cancellationCheck()
        var referencedNodeIDs = Set<String>()
        referencedNodeIDs.reserveCapacity(snapshot.recordLinks.count * 2)
        for (index, link) in snapshot.recordLinks.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            referencedNodeIDs.insert(link.fromNodeID)
            referencedNodeIDs.insert(link.toNodeID)
        }

        try cancellationCheck()
        var shellsByID: [UUID: PlanRecord] = [:]
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard isShell(
                plan,
                referencedRecordIDs: referencedRecordIDs,
                referencedNodeIDs: referencedNodeIDs
            ) else { continue }
            shellsByID[plan.id] = plan
        }
        try cancellationCheck()
        guard !shellsByID.isEmpty else { return }

        try cancellationCheck()
        var memos = snapshot.memos
        for index in memos.indices {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let planID = memos[index].planID,
                  let shell = shellsByID[planID] else { continue }
            memos[index].planID = nil
            if memos[index].targetID == "plan.\(planID.uuidString)" {
                memos[index].targetID = nil
            }
            memos[index].categoryID = memos[index].categoryID
                ?? shell.categoryID
            memos[index].occurredAt = shell.span.start
        }

        try cancellationCheck()
        var plans: [PlanRecord] = []
        plans.reserveCapacity(snapshot.plans.count - shellsByID.count)
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if shellsByID[plan.id] == nil { plans.append(plan) }
        }

        try cancellationCheck()
        snapshot.memos = memos
        snapshot.plans = plans
    }
}

enum PhotoClusterer {
    static func cluster(
        _ photos: [PhotoMoment],
        threshold: TimeInterval = 20 * 60
    ) -> [PhotoCluster] {
        let visible = photos
            .filter { !$0.isHiddenFromTimeline }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard var first = visible.first else { return [] }
        var current = [first]
        var clusters: [PhotoCluster] = []

        func appendCluster(_ values: [PhotoMoment]) {
            guard let representative = values.first(where: \.isFavorite) ?? values.first else {
                return
            }
            clusters.append(
                PhotoCluster(
                    id: representative.id,
                    representative: representative,
                    photos: values
                )
            )
        }

        for photo in visible.dropFirst() {
            if photo.capturedAt.timeIntervalSince(first.capturedAt) <= threshold {
                current.append(photo)
            } else {
                appendCluster(current)
                current = [photo]
            }
            first = photo
        }
        appendCluster(current)
        return clusters
    }

    static func nearestCluster(
        to date: Date,
        in photos: [PhotoMoment],
        tolerance: TimeInterval,
        threshold: TimeInterval = 20 * 60
    ) -> PhotoCluster? {
        let searchRadius = max(0, tolerance) + max(0, threshold)
        let candidates = photos.filter {
            !$0.isHiddenFromTimeline
                && abs($0.capturedAt.timeIntervalSince(date)) <= searchRadius
        }
        return cluster(candidates, threshold: threshold)
            .filter { cluster in
                guard let start = cluster.photos.first?.capturedAt,
                      let end = cluster.photos.last?.capturedAt else {
                    return false
                }
                return start.addingTimeInterval(-tolerance) <= date
                    && date <= end.addingTimeInterval(tolerance)
            }
            .min {
                abs($0.capturedAt.timeIntervalSince(date))
                    < abs($1.capturedAt.timeIntervalSince(date))
            }
    }
}
