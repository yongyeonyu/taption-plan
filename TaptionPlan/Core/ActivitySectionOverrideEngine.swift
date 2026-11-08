import Foundation
import TaptionPlanEngine

/// 겹침 제거 뒤 하나의 자동 기록이 여러 표시 조각으로 갈렸을 때, 사용자가
/// 고른 조각만 수동 파생 기록으로 교정한다. 센서 원본 전체에 교정을 걸면
/// 떨어져 보이는 다른 조각까지 함께 바뀌므로 표시 구간을 별도 ID로 보존한다.
enum ActivityFragmentCorrectionEngine {
    static func needsSeparateRecord(
        source: ActualRecord,
        displayedSpan: TimeSpan,
        tolerance: TimeInterval = 1
    ) -> Bool {
        guard let sourceEnd = source.endedAt else { return true }
        return abs(source.startedAt.timeIntervalSince(displayedSpan.start))
                > tolerance
            || abs(sourceEnd.timeIntervalSince(displayedSpan.end)) > tolerance
    }

    static func record(
        source: ActualRecord,
        displayedSpan: TimeSpan,
        correctedSpan: TimeSpan,
        option: ActivityCorrectionOption?,
        createdAt: Date = .now
    ) -> ActualRecord {
        ActualRecord(
            id: stableID(sourceID: source.id, span: displayedSpan),
            planID: source.planID,
            routineID: source.routineID,
            title: option?.title ?? source.title,
            categoryID: option?.categoryID ?? source.categoryID,
            startedAt: correctedSpan.start,
            endedAt: correctedSpan.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: option?.behavior ?? source.behavior,
            evidence: ["사용자가 표시 구간을 분류함"],
            modelVersion: "manual-activity-fragment-v1",
            manuallyCorrected: true
        )
    }

    static func stableID(sourceID: UUID, span: TimeSpan) -> UUID {
        let start = ActivitySectionOverrideEngine.milliseconds(span.start)
        let end = ActivitySectionOverrideEngine.milliseconds(span.end)
        let seed = "activity-fragment.\(sourceID.uuidString).\(start).\(end)"
        return StableRecordID.foldedFNV(seed)
    }
}

struct ActivitySectionOverridePiece: Hashable, Sendable {
    var span: TimeSpan
    var option: ActivityCorrectionOption
}

enum ActivitySectionEditMode: Hashable, Sendable {
    case replace(editedSpan: TimeSpan, option: ActivityCorrectionOption)
    case cutLowerUnconfirmed(
        cutAt: Date,
        option: ActivityCorrectionOption
    )
    case insertDetail(
        detailSpan: TimeSpan,
        option: ActivityCorrectionOption
    )
    /// NLE 클립 편집. 원본 구간을 여러 조각으로 다시 덮는다. 조각 사이에 빈 곳이
    /// 생기면 `fill`로 채우므로, 하루 전체가 언제나 빈틈없이 이어진다.
    /// 대분류는 미확인으로, 서브클립은 상위 분류로 메운다.
    case cover(
        pieces: [ActivitySectionOverridePiece],
        fill: ActivityCorrectionOption
    )
}

struct ActivitySectionEditRequest: Hashable, Sendable {
    var sourceIDs: [UUID]
    var originalSpan: TimeSpan
    var originalOption: ActivityCorrectionOption
    var mode: ActivitySectionEditMode
}

struct ActivitySectionEditSaveResult: Hashable, Sendable {
    var recordIDs: [UUID]
    var selectedSpan: TimeSpan
}

/// Builds user-owned display records over immutable sensor and travel data.
/// Every plan covers the original section without gaps, so shrinking or
/// slicing a section never exposes a stale automatic candidate underneath.
enum ActivitySectionOverrideEngine {
    static let modelVersion = "manual-activity-section-v2"

    static let unconfirmedOption = ActivityCorrectionOption(
        id: "phase.unconfirmed",
        title: "미확인",
        behavior: "unconfirmed-gap",
        categoryID: "unconfirmed",
        systemImage: "questionmark",
        isAutomatic: false,
        isCustom: false
    )

    static func pieces(
        for request: ActivitySectionEditRequest
    ) -> [ActivitySectionOverridePiece] {
        let original = request.originalSpan
        let values: [ActivitySectionOverridePiece]
        switch request.mode {
        case let .replace(editedSpan, option):
            guard let edited = editedSpan.intersection(with: original) else {
                return []
            }
            values = coveragePieces(
                original: original,
                middle: edited,
                middleOption: option,
                outsideOption: unconfirmedOption
            )

        case let .cutLowerUnconfirmed(cutAt, option):
            guard cutAt > original.start, cutAt < original.end else { return [] }
            values = [
                ActivitySectionOverridePiece(
                    span: TimeSpan(start: original.start, end: cutAt),
                    option: option
                ),
                ActivitySectionOverridePiece(
                    span: TimeSpan(start: cutAt, end: original.end),
                    option: unconfirmedOption
                ),
            ]

        case let .insertDetail(detailSpan, option):
            guard let detail = detailSpan.intersection(with: original) else {
                return []
            }
            values = coveragePieces(
                original: original,
                middle: detail,
                middleOption: option,
                outsideOption: request.originalOption
            )

        case let .cover(proposed, fill):
            values = coveringPieces(proposed, original: original, fill: fill)
        }
        return coalesced(values)
    }

    /// 제안한 조각들을 원본 구간 안으로 잘라 담고, 남는 곳은 `fill`로 채운다.
    /// 조각이 겹치면 뒤에 온 조각이 이긴다(타임라인의 위층 클립처럼).
    static func coveringPieces(
        _ proposed: [ActivitySectionOverridePiece],
        original: TimeSpan,
        fill: ActivityCorrectionOption = unconfirmedOption
    ) -> [ActivitySectionOverridePiece] {
        var clipped: [ActivitySectionOverridePiece] = []
        for piece in proposed {
            guard let span = piece.span.intersection(with: original) else {
                continue
            }
            var trimmed = piece
            trimmed.span = span
            clipped.append(trimmed)
        }
        clipped.sort { $0.span.start < $1.span.start }

        var values: [ActivitySectionOverridePiece] = []
        var cursor = original.start
        for piece in clipped {
            if piece.span.start > cursor {
                values.append(ActivitySectionOverridePiece(
                    span: TimeSpan(start: cursor, end: piece.span.start),
                    option: fill
                ))
            }
            let start = max(cursor, piece.span.start)
            guard start < piece.span.end else { continue }
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: start, end: piece.span.end),
                option: piece.option
            ))
            cursor = max(cursor, piece.span.end)
        }
        if cursor < original.end {
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: cursor, end: original.end),
                option: fill
            ))
        }
        return values
    }

    static func records(
        for request: ActivitySectionEditRequest,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        pieces(for: request).map { piece in
            ActualRecord(
                id: stableID(
                    sourceIDs: request.sourceIDs,
                    originalSpan: request.originalSpan,
                    piece: piece
                ),
                planID: nil,
                title: piece.option.title,
                categoryID: piece.option.categoryID,
                startedAt: piece.span.start,
                endedAt: piece.span.end,
                source: .manual,
                confidence: .high,
                createdAt: createdAt,
                behavior: piece.option.behavior,
                evidence: ["사용자가 행동 구간을 편집함"],
                modelVersion: modelVersion,
                manuallyCorrected: true
            )
        }
    }

    static func isEditableOverride(_ actual: ActualRecord) -> Bool {
        actual.source == .manual && actual.manuallyCorrected
    }

    static func outsidePieces(
        of actual: ActualRecord,
        replacing span: TimeSpan
    ) -> [ActualRecord] {
        guard let end = actual.endedAt else { return [] }
        var pieces: [ActualRecord] = []
        if actual.startedAt < span.start {
            var before = actual
            before.id = UUID()
            before.endedAt = min(end, span.start)
            if before.startedAt < min(end, span.start) { pieces.append(before) }
        }
        if span.end < end {
            var after = actual
            after.id = UUID()
            after.startedAt = max(actual.startedAt, span.end)
            if after.startedAt < end { pieces.append(after) }
        }
        return pieces
    }

    private static func coveragePieces(
        original: TimeSpan,
        middle: TimeSpan,
        middleOption: ActivityCorrectionOption,
        outsideOption: ActivityCorrectionOption
    ) -> [ActivitySectionOverridePiece] {
        var values: [ActivitySectionOverridePiece] = []
        if original.start < middle.start {
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: original.start, end: middle.start),
                option: outsideOption
            ))
        }
        values.append(ActivitySectionOverridePiece(
            span: middle,
            option: middleOption
        ))
        if middle.end < original.end {
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: middle.end, end: original.end),
                option: outsideOption
            ))
        }
        return values
    }

    private static func coalesced(
        _ pieces: [ActivitySectionOverridePiece]
    ) -> [ActivitySectionOverridePiece] {
        pieces.reduce(into: []) { result, piece in
            guard piece.span.duration > 0 else { return }
            guard var previous = result.last,
                  previous.span.end == piece.span.start,
                  previous.option.title == piece.option.title,
                  previous.option.categoryID == piece.option.categoryID,
                  previous.option.behavior == piece.option.behavior
            else {
                result.append(piece)
                return
            }
            result.removeLast()
            previous.span = TimeSpan(
                start: previous.span.start,
                end: piece.span.end
            )
            result.append(previous)
        }
    }

    private static func stableID(
        sourceIDs: [UUID],
        originalSpan: TimeSpan,
        piece: ActivitySectionOverridePiece
    ) -> UUID {
        let sources = sourceIDs.map(\.uuidString).sorted().joined(separator: ",")
        let seed = [
            modelVersion,
            sources,
            milliseconds(originalSpan.start),
            milliseconds(originalSpan.end),
            milliseconds(piece.span.start),
            milliseconds(piece.span.end),
            piece.option.categoryID,
            piece.option.behavior ?? "",
            piece.option.title,
        ].joined(separator: ".")
        return StableRecordID.foldedFNV(seed)
    }

    /// 안정 ID 씨앗에 쓰는 밀리초 정수 문자열. 조각 교정도 같은 표기를 쓴다.
    fileprivate static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}
