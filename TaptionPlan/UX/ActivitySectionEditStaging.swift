import Foundation
import TaptionPlanCore

/// 구간 편집 요청 하나를 스냅숏 값에 반영한다. 저장은 하지 않는다.
///
/// 요청마다 `AppModel.snapshot`을 고치고 저장하면 여러 구간을 한 번에 고칠 때 앞 요청만
/// 저장된 채 남을 수 있다. 값에만 반영해 두고 저장은 부르는 쪽이 한 번에 한다(OVW1108A01).
/// 센서·자동 기록은 지우지 않고, 사용자 소유 덮개 기록만 바꾼다.
enum ActivitySectionEditStaging {
    struct Stage: Equatable {
        let records: [ActualRecord]
        let preservedPieces: [ActualRecord]
        let editedSpan: TimeSpan

        /// 저장 뒤 되읽어 확인할 기록. 수면 조각은 확정 수면 기록이 대신하므로 뺀다.
        var expectedIDs: Set<UUID> {
            Set((records.filter { $0.categoryID != NLEOverwritePolicy.sleepCategoryID } + preservedPieces).map(\.id))
        }
    }

    /// 확정 수면을 어떻게 고칠지.
    enum SleepRule {
        /// 대표 구간(가장 긴 조각) 하나로 판단한다. 한 구간만 고치는 예전 경로.
        case primarySpan
        /// 조각마다 판단한다. 수면 조각은 더하고 나머지 조각의 수면은 뺀다.
        case perPiece
    }

    static func stage(
        _ request: ActivitySectionEditRequest,
        into snapshot: inout TaptionDataSnapshot,
        sleepRule: SleepRule,
        createdAt: Date = .now
    ) -> Stage? {
        let records = ActivitySectionOverrideEngine.records(for: request, createdAt: createdAt)
        guard !records.isEmpty else { return nil }
        let sourceIDs = Set(request.sourceIDs)
        let preservedPieces = snapshot.actuals
            .filter {
                sourceIDs.contains($0.id)
                    && ActivitySectionOverrideEngine.isEditableOverride($0)
            }
            .flatMap {
                ActivitySectionOverrideEngine.outsidePieces(
                    of: $0,
                    replacing: request.originalSpan
                )
            }
        var actuals = snapshot.actuals
        actuals.removeAll { actual in
            sourceIDs.contains(actual.id)
                && ActivitySectionOverrideEngine.isEditableOverride(actual)
        }
        actuals = ActivitySectionOverrideEngine.removingOverrides(from: actuals, sameSpanAs: records)
        actuals.append(contentsOf: preservedPieces)
        actuals.append(contentsOf: records)
        actuals.sort { $0.startedAt < $1.startedAt }
        snapshot.actuals = actuals
        for option in editedOptions(in: request.mode) where option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        let editedSpan = primarySpan(for: request)
        switch sleepRule {
        case .primarySpan:
            if editedOptions(in: request.mode).contains(where: { $0.categoryID == NLEOverwritePolicy.sleepCategoryID }) {
                replaceConfirmedSleep(in: &snapshot, adding: [editedSpan])
            } else {
                replaceConfirmedSleep(in: &snapshot, removing: [editedSpan])
            }
        case .perPiece:
            let pieces = ActivitySectionOverrideEngine.pieces(for: request)
            let isSleep: (ActivitySectionOverridePiece) -> Bool = {
                $0.option.categoryID == NLEOverwritePolicy.sleepCategoryID
            }
            replaceConfirmedSleep(
                in: &snapshot,
                removing: pieces.filter { !isSleep($0) }.map(\.span),
                adding: pieces.filter(isSleep).map(\.span)
            )
        }
        return Stage(records: records, preservedPieces: preservedPieces, editedSpan: editedSpan)
    }

    static func replaceConfirmedSleep(
        in snapshot: inout TaptionDataSnapshot,
        removing: [TimeSpan] = [],
        adding: [TimeSpan] = []
    ) {
        snapshot.settings.confirmedSleepSpans = ConfirmedSleepSpanEditor.replacing(
            snapshot.settings.confirmedSleepSpans,
            removing: removing,
            adding: adding
        )
        snapshot.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: snapshot.actuals
        )
    }

    static func editedOptions(
        in mode: ActivitySectionEditMode
    ) -> [ActivityCorrectionOption] {
        switch mode {
        case let .replace(_, option), let .cutLowerUnconfirmed(_, option),
             let .insertDetail(_, option):
            return [option]
        case let .cover(pieces, _):
            return pieces.map(\.option)
        }
    }

    static func primarySpan(
        for request: ActivitySectionEditRequest
    ) -> TimeSpan {
        switch request.mode {
        case let .replace(editedSpan, _):
            return editedSpan.intersection(with: request.originalSpan)
                ?? request.originalSpan
        case let .cutLowerUnconfirmed(cutAt, _):
            return TimeSpan(start: request.originalSpan.start, end: cutAt)
        case let .insertDetail(detailSpan, _):
            return detailSpan.intersection(with: request.originalSpan)
                ?? request.originalSpan
        case let .cover(pieces, _):
            // 가장 긴 조각을 대표 구간으로 삼는다(선택 표시용).
            return pieces
                .map(\.span)
                .max { $0.duration < $1.duration }
                ?? request.originalSpan
        }
    }
}
