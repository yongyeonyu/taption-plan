import Foundation
import TaptionPlanCore

extension AppModel {
    /// 클립 편집기의 요청 전부를 한 번에 저장한다(OVW1108A01).
    ///
    /// 모두 아니면 아무것도: 요청을 스냅숏 값에 차례로 반영한 뒤 저장소에 한 번만 쓴다.
    /// 저장이나 되읽기 확인이 실패하면 메모리·저장소를 편집 전으로 되돌리고 `false`를
    /// 돌려준다. 성공하면 사용자 편집 되돌리기 기록에 한 칸만 남긴다.
    ///
    /// 대분류 요청을 먼저, 상세활동 요청을 나중에 넣는다. 상세활동 구간은 대분류 구간
    /// 안에 있으므로 나중에 덮어야 상세활동이 살아남는다. 대분류는 조각마다 수면을 판단하고,
    /// 상세활동은 예전처럼 대표 구간으로 판단한다(상세가 대분류의 수면을 자르지 않게).
    func saveClipEditBatch(
        main: [ActivitySectionEditRequest],
        detail: [ActivitySectionEditRequest]
    ) async -> Bool {
        guard !main.isEmpty || !detail.isEmpty else { return true }
        guard acceptsDataMutation() else { return false }
        let previous = snapshot
        var staged = snapshot
        var expectedIDs = Set<UUID>()
        let createdAt = Date.now
        let ordered = main.map { ($0, ActivitySectionEditStaging.SleepRule.perPiece) }
            + detail.map { ($0, ActivitySectionEditStaging.SleepRule.primarySpan) }
        for (request, rule) in ordered {
            guard let stage = ActivitySectionEditStaging.stage(
                request, into: &staged, sleepRule: rule, createdAt: createdAt
            ) else {
                recordClipBatchFailure("stage", requestCount: ordered.count)
                return false
            }
            expectedIDs.formUnion(stage.expectedIDs)
        }
        guard staged != previous else { return true }
        snapshot = staged
        // 저장이 실패했을 때 다른 변경을 지우지 않고 이번 편집만 빼내는 데 쓴다.
        let batchEntry = AppModelHistoryEntry.difference(
            from: previous, to: staged, includesAutomaticActuals: true
        )
        let editRevision = snapshotRevision

        guard await persist() else {
            rollBackClipBatch(to: previous, entry: batchEntry, editRevision: editRevision)
            recordClipBatchFailure("persist", requestCount: ordered.count)
            return false
        }

        // 뒤 요청이 앞 요청의 조각을 지웠을 수 있으므로 지금 남아 있는 것만 확인한다.
        let stillPresent = expectedIDs.intersection(snapshot.actuals.map(\.id))
        let verified: Bool
        do {
            let stored = try await repository.existingActualIDs(stillPresent)
            verified = stillPresent.isSubset(of: stored)
        } catch {
            verified = false
        }
        guard verified else {
            // 저장소에 반쯤 남은 상태를 두지 않는다. 편집 전 값으로 다시 쓴다.
            rollBackClipBatch(to: previous, entry: batchEntry, editRevision: nil)
            await persist()
            recordClipBatchFailure("readback", requestCount: ordered.count)
            return false
        }

        recordUserEdit(from: previous, includesAutomaticActuals: true)
        TaptionPlanDiagnosticsLogger.shared.record(
            "nle_clip_edit_applied",
            fields: [
                "request_count": String(ordered.count),
                "applied_count": String(ordered.count),
                "batch": "true",
            ]
        )
        return true
    }

    /// 이번 편집만 빼낸다. 그 사이 다른 변경이 없으면 편집 전 값 그대로, 있으면 이번 편집의 역을 적용한다.
    private func rollBackClipBatch(
        to previous: TaptionDataSnapshot,
        entry: AppModelHistoryEntry,
        editRevision: UInt64?
    ) {
        if let editRevision, snapshotRevision == editRevision {
            snapshot = previous
            return
        }
        snapshot = entry.applying(to: snapshot, undo: true) ?? previous
    }

    private func recordClipBatchFailure(_ stage: String, requestCount: Int) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "nle_clip_edit_failed",
            level: .error,
            fields: ["stage": stage, "request_count": String(requestCount)]
        )
    }
}
