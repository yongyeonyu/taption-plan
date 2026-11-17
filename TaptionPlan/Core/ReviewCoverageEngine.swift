import Foundation
import TaptionPlanEngine

/// 기록 화면은 같은 시각에 들어온 센서 결과를 모두 더하지 않는다. 수면처럼
/// 더 구체적인 기록을 먼저 남기고 겹친 하위 신뢰 기록을 잘라 낸 뒤, 측정되지
/// 않은 과거만 `미확인`으로 채운다. 저장된 원본은 건드리지 않는다.
enum ReviewCoverageEngine {
    static let unconfirmedCategoryID = "unconfirmed"

    static func records(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        asOf: Date = .now
    ) -> [ActualRecord] {
        let targets = ActualIntervalMergeEngine.union(
            spans.compactMap { span in
                let end = min(span.end, asOf)
                return end > span.start
                    ? TimeSpan(start: span.start, end: end)
                    : nil
            },
            mergeGap: 0
        )
        guard !targets.isEmpty else { return [] }

        // 우선순위는 비교마다 다시 세지 않고 한 번만 센다(글자 비교가 들어 있어 비쌈, PRF1117A02).
        // 어느 대상 구간과도 겹치지 않는 기록은 아래 반복에서 늘 건너뛰므로 정렬 전에 뺀다. 결과는 같다.
        let unique = Dictionary(
            actuals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
            .filter { actual in
                if PerfBenchBefore.has("coverage") { return true }
                let span = actual.span(asOf: asOf)
                return targets.contains { span.intersection(with: $0) != nil }
            }
            .map { Ranked(actual: $0, precedence: precedence($0)) }
            .sorted(by: PerfBenchBefore.has("coverage") ? isHigherPriorityRecounting : isHigherPriority)
        var pieceOffsets: [UUID: Int] = [:]
        var result: [Ranked] = []

        for target in targets {
            var covered: [TimeSpan] = []
            for ranked in unique {
                let actual = ranked.actual
                guard let visible = actual.span(asOf: asOf)
                    .intersection(with: target) else { continue }
                let remainders = ActualIntervalMergeEngine.subtracting(
                    covered,
                    from: visible
                )
                for remainder in remainders where remainder.duration > 0 {
                    let offset = pieceOffsets[actual.id, default: 0]
                    pieceOffsets[actual.id] = offset + 1
                    var piece = actual
                    piece.id = offset == 0
                        ? actual.id
                        : stableID(
                            "record.\(actual.id.uuidString).\(offset)"
                        )
                    piece.startedAt = remainder.start
                    piece.endedAt = remainder.end
                    result.append(Ranked(actual: piece, precedence: ranked.precedence))
                    covered.append(remainder)
                }
            }

            for gap in ActualIntervalMergeEngine.subtracting(
                covered,
                from: target
            ) where gap.duration > 0 {
                let record = unconfirmedRecord(for: gap)
                result.append(Ranked(actual: record, precedence: precedence(record)))
            }
        }
        return result.sorted {
            $0.actual.startedAt == $1.actual.startedAt
                ? $0.precedence > $1.precedence
                : $0.actual.startedAt < $1.actual.startedAt
        }.map(\.actual)
    }

    private struct Ranked {
        let actual: ActualRecord
        let precedence: Int
    }

    static func unconfirmedRecords(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        asOf: Date = .now
    ) -> [ActualRecord] {
        records(actuals: actuals, in: spans, asOf: asOf).filter {
            $0.categoryID == unconfirmedCategoryID
        }
    }

    /// 고치기 전처럼 비교마다 우선순위를 다시 센다(`-benchBefore=coverage`, 전후 비교용).
    private static func isHigherPriorityRecounting(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
        isHigherPriority(
            Ranked(actual: lhs.actual, precedence: precedence(lhs.actual)),
            Ranked(actual: rhs.actual, precedence: precedence(rhs.actual))
        )
    }

    private static func isHigherPriority(
        _ leftRanked: Ranked,
        _ rightRanked: Ranked
    ) -> Bool {
        let lhs = leftRanked.actual, rhs = rightRanked.actual
        let left = leftRanked.precedence
        let right = rightRanked.precedence
        if left != right { return left > right }
        if lhs.confidence != rhs.confidence {
            return confidence(lhs.confidence) > confidence(rhs.confidence)
        }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func precedence(_ actual: ActualRecord) -> Int {
        if AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) {
            return 1_300
        }
        if AutomaticRecordTimelineEngine.isSleep(actual) { return 1_200 }
        if actual.manuallyCorrected || actual.source == .manual { return 1_100 }
        let category = ActualRecordCategoryResolver.categoryID(for: actual)
        return switch category {
        case "movement": 800
        case "activity", "exercise", "health": 700
        case "work", "study", "routine": 600
        case "rest": 500
        case "appUsage": 100
        case unconfirmedCategoryID: 0
        default: 400
        }
    }

    private static func confidence(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private static func unconfirmedRecord(for span: TimeSpan) -> ActualRecord {
        ActualRecord(
            id: stableID(
                "gap.\(span.start.timeIntervalSince1970).\(span.end.timeIntervalSince1970)"
            ),
            planID: nil,
            title: "미확인",
            categoryID: unconfirmedCategoryID,
            startedAt: span.start,
            endedAt: span.end,
            source: .motion,
            confidence: .low,
            createdAt: span.end,
            behavior: "unconfirmed-gap",
            evidence: ["자동 기록이 없는 시간"],
            modelVersion: "review-coverage-v1"
        )
    }

    private static func stableID(_ seed: String) -> UUID {
        StableRecordID.foldedFNV(seed)
    }
}

/// 일과는 이동 표시용으로 합쳐진 사본이 아니라 HealthKit·Apple Watch 원본을
/// 읽는다. 그래야 같은 걷기가 활동에서는 `걷기`, 일과에서는 `운동`이 된다.
enum DayPhaseEvidenceEngine {
    static func records(
        from actuals: [ActualRecord],
        intersecting span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        AutomaticRecordTimelineEngine.visibleThroughNow(
            actuals,
            intersecting: span,
            asOf: asOf
        )
    }
}
