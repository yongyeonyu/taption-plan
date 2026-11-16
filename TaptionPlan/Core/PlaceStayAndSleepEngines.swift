import Foundation
import TaptionPlanCore

/// Keeps raw stays intact while showing one block for duplicate place results.
enum PlaceStayPresentationEngine {
    static func consolidated(_ stays: [PlaceStay]) -> [PlaceStay] {
        let samePlaceValues = mergeSamePlaceDuplicates(stays)
        var result: [PlaceStay] = []
        for stay in samePlaceValues {
            let overlappingIndices = result.indices.filter {
                result[$0].span.intersection(with: stay.span) != nil
            }
            guard !overlappingIndices.isEmpty else {
                result.append(stay)
                continue
            }

            // 위치 센서는 같은 시간에 서로 다른 장소 후보를 만들 수 있다.
            // 표시에서는 가장 신뢰할 수 있는 후보 하나만 남기되 원본 기록은
            // 건드리지 않는다. 새 후보가 기존 후보 모두보다 정확할 때만
            // 교체하므로 결과에는 겹치는 위치 막대가 생기지 않는다.
            guard overlappingIndices.allSatisfy({
                isPreferred(stay, over: result[$0])
            }) else {
                continue
            }
            for index in overlappingIndices.reversed() {
                result.remove(at: index)
            }
            result.append(stay)
        }
        return result.sorted(by: chronological)
    }

    private static func mergeSamePlaceDuplicates(
        _ stays: [PlaceStay]
    ) -> [PlaceStay] {
        var result: [PlaceStay] = []
        for stay in stays.sorted(by: chronological) {
            var value = stay
            for index in result.indices.reversed()
            where overlapsSamePlace(result[index], value) {
                value = merged(result.remove(at: index), value)
            }
            result.append(value)
        }
        return result.sorted(by: chronological)
    }

    private static func overlapsSamePlace(
        _ lhs: PlaceStay,
        _ rhs: PlaceStay
    ) -> Bool {
        let samePlace = (!lhs.placeKey.isEmpty && lhs.placeKey == rhs.placeKey)
            || normalized(lhs.displayName) == normalized(rhs.displayName)
        let sameFloor = lhs.floor == rhs.floor
            || lhs.floor == nil
            || rhs.floor == nil
        return samePlace && sameFloor
            && lhs.span.intersection(with: rhs.span) != nil
    }

    private static func merged(
        _ lhs: PlaceStay,
        _ rhs: PlaceStay
    ) -> PlaceStay {
        let preferred = isPreferred(rhs, over: lhs) ? rhs : lhs
        let fallback = preferred.id == lhs.id ? rhs : lhs
        var value = preferred
        value.span = TimeSpan(
            start: min(lhs.span.start, rhs.span.start),
            end: max(lhs.span.end, rhs.span.end)
        )
        value.confidence = confidenceRank(lhs.confidence)
            >= confidenceRank(rhs.confidence) ? lhs.confidence : rhs.confidence
        value.isConfirmed = lhs.isConfirmed || rhs.isConfirmed
        value.buildingName = value.buildingName ?? fallback.buildingName
        value.floor = value.floor ?? fallback.floor
        value.floorEvidence = value.floorEvidence ?? fallback.floorEvidence
        value.point = value.point ?? fallback.point
        return value
    }

    private static func isPreferred(
        _ lhs: PlaceStay,
        over rhs: PlaceStay
    ) -> Bool {
        let leftScore = score(lhs)
        let rightScore = score(rhs)
        if leftScore != rightScore { return leftScore > rightScore }
        let leftHorizontalAccuracy = validAccuracy(
            lhs.point?.horizontalAccuracy
        )
        let rightHorizontalAccuracy = validAccuracy(
            rhs.point?.horizontalAccuracy
        )
        if leftHorizontalAccuracy != rightHorizontalAccuracy {
            return leftHorizontalAccuracy < rightHorizontalAccuracy
        }
        let leftVerticalAccuracy = validAccuracy(lhs.point?.verticalAccuracy)
        let rightVerticalAccuracy = validAccuracy(rhs.point?.verticalAccuracy)
        if leftVerticalAccuracy != rightVerticalAccuracy {
            return leftVerticalAccuracy < rightVerticalAccuracy
        }
        if lhs.span.duration != rhs.span.duration {
            return lhs.span.duration > rhs.span.duration
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func score(_ stay: PlaceStay) -> Int {
        (stay.isConfirmed ? 32 : 0)
            + confidenceRank(stay.confidence) * 8
            + (
                validAccuracy(stay.point?.horizontalAccuracy).isFinite
                    ? 4
                    : 0
            )
            + (stay.floorEvidence == nil ? 0 : 2)
            + (stay.floor == nil ? 0 : 1)
    }

    private static func validAccuracy(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else {
            return .infinity
        }
        return value
    }

    private static func confidenceRank(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func chronological(_ lhs: PlaceStay, _ rhs: PlaceStay) -> Bool {
        lhs.span.start == rhs.span.start
            ? lhs.span.end < rhs.span.end
            : lhs.span.start < rhs.span.start
    }
}

/// HealthKit sleep sessions are authoritative for the time they cover.  The
/// motion/location records that were previously classified as generic
/// activity are derived display records, so they can be trimmed without
/// changing the archived sensor stream.
enum SleepActualReconciliationEngine {
    static let modelVersion = "healthkit-sleep-reconciled-v1"

    static func coveredAutomaticIDs(
        in actuals: [ActualRecord],
        by sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date = .now
    ) -> Set<UUID> {
        let sleepSpans = sleepSpans(
            sessions,
            inside: span,
            asOf: date
        )
        guard !sleepSpans.isEmpty else { return [] }
        return Set(actuals.compactMap { actual in
            guard shouldTrim(actual),
                  let overlap = sleepOverlap(
                      actual.span(asOf: date),
                      with: sleepSpans
                  ),
                  overlap.duration > 0 else {
                return nil
            }
            return actual.id
        })
    }

    static func applying(
        _ actuals: [ActualRecord],
        sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let spans = sleepSpans(sessions, inside: span, asOf: date)
        guard !spans.isEmpty else { return actuals }

        var result: [ActualRecord] = []
        var authoritativeIDs = Set<UUID>()
        for actual in actuals {
            let actualSpan = actual.span(asOf: date)
            guard sleepOverlap(actualSpan, with: spans) != nil else {
                result.append(actual)
                continue
            }

            if isAuthoritativeSleep(actual) {
                var normalized = actual
                normalized.title = "수면"
                normalized.categoryID = "sleep"
                if sessions.contains(where: {
                    $0.isAppleWatchConfirmed
                        && $0.span.intersection(with: actualSpan) != nil
                }) {
                    normalized.source = .appleWatch
                }
                normalized.behavior = WatchBehaviorKind.sleep.rawValue
                normalized.evidence = Array(
                    Set(actual.evidence + ["HealthKit 수면 기록"])
                ).sorted()
                normalized.modelVersion = Self.modelVersion
                result.append(normalized)
                authoritativeIDs.insert(actual.id)
                continue
            }

            guard shouldTrim(actual) else {
                result.append(actual)
                continue
            }

            let remainders = ActualIntervalMergeEngine.subtracting(
                spans,
                from: actualSpan
            )
            for (offset, remainder) in remainders.enumerated() {
                var value = actual
                value.id = offset == 0
                    ? actual.id
                    : remainderID(of: actual.id, offset: offset)
                value.startedAt = remainder.start
                value.endedAt = remainder.end
                result.append(value)
            }
        }

        for session in sessions {
            guard let visible = session.span.intersection(with: span),
                  visible.start < min(visible.end, date),
                  !actuals.contains(where: { actual in
                      isAuthoritativeSleep(actual)
                          && actual.span(asOf: date).intersection(
                              with: visible
                          )?.duration ?? 0 > 0
                  }) else {
                continue
            }
            let end = min(visible.end, date)
            guard end > visible.start,
                  !authoritativeIDs.contains(session.id) else { continue }
            result.append(
                ActualRecord(
                    id: session.id,
                    planID: nil,
                    title: "수면",
                    categoryID: "sleep",
                    startedAt: visible.start,
                    endedAt: end,
                    source: session.isAppleWatchConfirmed
                        ? .appleWatch
                        : .healthKit,
                    confidence: .high,
                    createdAt: visible.start,
                    behavior: WatchBehaviorKind.sleep.rawValue,
                    evidence: ["HealthKit 수면 기록"],
                    modelVersion: Self.modelVersion
                )
            )
        }
        return AppleWatchNapPolicy.labeling(PhoneSleepFusion.droppingCovered(result, by: sessions, inside: span, asOf: date).sorted { $0.startedAt < $1.startedAt }, sessions: sessions, inside: span)
    }

    private static func sleepSpans(
        _ sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date
    ) -> [TimeSpan] {
        sessions.compactMap { session in
            guard let clipped = session.span.intersection(with: span) else {
                return nil
            }
            let end = min(clipped.end, date)
            guard end > clipped.start else { return nil }
            return TimeSpan(start: clipped.start, end: end)
        }
    }

    private static func sleepOverlap(
        _ actual: TimeSpan,
        with spans: [TimeSpan]
    ) -> TimeSpan? {
        let pieces = spans.compactMap { actual.intersection(with: $0) }
        guard let first = pieces.first else { return nil }
        let merged = ActualIntervalMergeEngine.union(pieces, mergeGap: 0)
        return merged.count == 1
            ? merged[0]
            : TimeSpan(start: first.start, end: merged.last?.end ?? first.end)
    }

    private static func isAuthoritativeSleep(_ actual: ActualRecord) -> Bool {
        (actual.source == .healthKit || actual.source == .appleWatch)
            && AutomaticRecordTimelineEngine.isSleep(actual)
    }

    private static func shouldTrim(_ actual: ActualRecord) -> Bool {
        guard actual.source == .motion || actual.source == .location else {
            return false
        }
        guard actual.categoryID != "appUsage",
              actual.categoryID != "exercise",
              !AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) else {
            return false
        }
        // 자동 이동(지하철 추정·빈칸 추정)도 수면 시간에서는 잘린다(CAT1029A01).
        return actual.categoryID == "activity" || actual.categoryID == "movement"
            || actual.categoryID == "rest"
            || actual.categoryID == "routine"
            || actual.behavior == "stationary"
            || actual.behavior == "homeRest"
            || actual.behavior == "cafe"
            || actual.behavior == "housework"
    }

    private static func remainderID(of id: UUID, offset: Int) -> UUID {
        StableRecordID.remainder(of: id, offset: offset)
    }
}
