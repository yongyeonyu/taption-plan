import Foundation
import TaptionPlanCore

/// 뒤에 줄 선 전체 저장이 이 저장을 대신했다는 표시.
struct SnapshotWriteSuperseded: Error {}

/// 전체 스냅샷 저장의 순번. 뒤에 줄 선 전체 저장이 있으면 앞의 값은 쓰지 않고
/// 그 결과를 따른다. 늦게 끝난 옛 값이 새 편집을 덮지 않게 한다(RVW1030A01).
@MainActor
final class SnapshotWriteLedger {
    private(set) var latestSequence: UInt64 = 0
    var latestTask: Task<Bool, Error>?

    func begin(_ sequence: UInt64) { latestSequence = max(latestSequence, sequence) }

    func isSuperseded(_ sequence: UInt64) -> Bool { sequence < latestSequence }

    func result(of task: Task<Bool, Error>) async throws -> Bool {
        var current = task
        while true {
            do {
                return try await current.value
            } catch is SnapshotWriteSuperseded {
                guard let newer = latestTask, newer != current else {
                    throw CancellationError()
                }
                current = newer
            }
        }
    }
}

/// 편집 직후에 잡아 둔 되돌리기 정보.
struct UserEditRollback {
    let before: TaptionDataSnapshot
    let change: AppModelHistoryEntry
    let editRevision: UInt64
    let generation: UInt64
    let historyItemID: UUID?
}

extension AppModel {
    /// 편집을 실행취소 기록에 남기고 저장한다. 저장하지 못하면 편집 전으로 되돌린다.
    @discardableResult
    func saveUserEdit(
        from before: TaptionDataSnapshot,
        coalescingKey: String? = nil,
        actualEdit: PlanActualEdit? = nil
    ) async -> Bool {
        let rollback = recordRollbackableEdit(from: before, coalescingKey: coalescingKey)
        return await persistOrRollBack(rollback, actualEdit: actualEdit)
    }

    /// 동기 편집용. 되돌리기 기준은 지금 잡고 저장은 뒤에서 한다.
    func scheduleUserEditSave(from before: TaptionDataSnapshot, coalescingKey: String? = nil) {
        let rollback = recordRollbackableEdit(from: before, coalescingKey: coalescingKey)
        Task { await persistOrRollBack(rollback) }
    }

    func userEditRollback(from before: TaptionDataSnapshot, historyItemID: UUID? = nil) -> UserEditRollback {
        UserEditRollback(
            before: before,
            change: .difference(from: before, to: snapshot),
            editRevision: snapshotRevision,
            generation: dataDeletionGeneration,
            historyItemID: historyItemID
        )
    }

    @discardableResult
    func persistOrRollBack(_ rollback: UserEditRollback, actualEdit: PlanActualEdit? = nil) async -> Bool {
        if await persist(actualEdit: actualEdit) { return true }
        rollBackUnsavedEdit(rollback)
        return false
    }

    /// 저장하지 못한 편집만 메모리에서 지운다. 그 사이 다른 변경이 있으면 이 편집의
    /// 차이만 거꾸로 적용하고, 디스크와 맞추려고 한 번 더 저장한다.
    func rollBackUnsavedEdit(_ rollback: UserEditRollback) {
        guard rollback.generation == dataDeletionGeneration,
              hasCurrentDataGeneration, !isDeletingUserData else { return }
        var reverted = false
        if snapshotRevision == rollback.editRevision {
            snapshot = rollback.before
            reverted = true
        } else if !rollback.change.isEmpty,
                  let restored = rollback.change.applying(to: snapshot, undo: true) {
            snapshot = restored
            reverted = true
            Task { await persist() }
        }
        if let id = rollback.historyItemID, userEditUndoHistory.last?.id == id {
            userEditUndoHistory.removeLast()
            synchronizeUserEditHistoryAvailability()
        }
        guard !lastPersistWasCancelled, userFacingError == nil else { return }
        userFacingError = reverted
            ? AppLanguagePreference.text(
                korean: "변경 내용을 저장하지 못해 편집 전으로 되돌렸습니다.",
                english: "Couldn't save the change, so it was undone."
            )
            : AppLanguagePreference.text(
                korean: "변경 내용을 저장하지 못했습니다.",
                english: "Could not save changes."
            )
    }

    private func recordRollbackableEdit(
        from before: TaptionDataSnapshot,
        coalescingKey: String?
    ) -> UserEditRollback {
        let lastID = userEditUndoHistory.last?.id
        recordUserEdit(from: before, coalescingKey: coalescingKey)
        let item = userEditUndoHistory.last
        // 이어 끌기로 합쳐진 항목은 앞서 저장된 편집도 담고 있어 지우지 않는다.
        let addedID = item?.id != lastID && item?.coalescingKey == nil ? item?.id : nil
        return userEditRollback(from: before, historyItemID: addedID)
    }
}
