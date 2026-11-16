import Foundation
import TaptionPlanEngine

private struct ActivityClassificationIntervalIndex<Value> {
    private struct Entry {
        let value: Value
        let span: TimeSpan
        let inputOrder: Int
    }

    private let entries: [Entry]
    private let prefixMaximumEnds: [Date]

    init(
        _ values: [(inputOrder: Int, value: Value)],
        span: (Value) -> TimeSpan
    ) {
        entries = values
            .map { value in
                Entry(
                    value: value.value,
                    span: span(value.value),
                    inputOrder: value.inputOrder
                )
            }
            .sorted {
                if $0.span.start != $1.span.start {
                    return $0.span.start < $1.span.start
                }
                return $0.inputOrder < $1.inputOrder
            }

        var latestEnd = Date.distantPast
        prefixMaximumEnds = entries.map { entry in
            latestEnd = max(latestEnd, entry.span.end)
            return latestEnd
        }
    }

    func forEachCandidate(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?,
        _ body: (Value, Int) -> Void
    ) {
        guard span.start < span.end, !entries.isEmpty else { return }

        var lower = 0
        var upper = prefixMaximumEnds.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if prefixMaximumEnds[middle] > span.start {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let firstCandidate = lower

        upper = entries.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if entries[middle].span.start < span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        for entry in entries[firstCandidate..<lower] {
            inspectionCount? += 1
            body(entry.value, entry.inputOrder)
        }
    }
}

/// Makes automatic major-category decisions durable without touching the
/// sensor archive. A refresh may produce a new span or more evidence, but a
/// stored automatic record keeps its previous category unless a registered
/// destination resolves an earlier unknown stay. Explicit activity corrections
/// remain the only user override.
enum ActivityClassificationLockEngine {
    static func lockingAutomaticClassifications(_ actuals: [ActualRecord]) -> [ActualRecord] {
        lockingAutomaticClassifications(actuals, cancellationCheck: {})
    }

    static func lockingAutomaticClassifications(
        _ actuals: [ActualRecord],
        cancellationCheck: () throws -> Void
    ) rethrows -> [ActualRecord] {
        try cancellationCheck()
        var locked: [ActualRecord] = []
        locked.reserveCapacity(actuals.count)
        for (index, actual) in actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard actual.source.usesAutomaticClassification else {
                locked.append(actual)
                continue
            }
            var value = actual
            if !value.isClassificationLocked { value.lockReason = value.lockReason ?? value.defaultLockReason }
            value.isClassificationLocked = true
            locked.append(value)
        }
        try cancellationCheck()
        return locked
    }

    static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan
    ) -> [ActualRecord] {
        var inspectionCount: Int? = nil
        return mergingLockedClassifications(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
    }

    static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [ActualRecord] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = mergingLockedClassifications(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount ?? candidateInspectionCount
        return result
    }

    private static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan,
        inspectionCount: inout Int?
    ) -> [ActualRecord] {
        let locked = existing.filter { actual in
            actual.isClassificationLocked
                && actual.source.usesAutomaticClassification
                && actual.span(asOf: inside.end).intersection(with: inside) != nil
        }
        var groupedLocked: [String: [(inputOrder: Int, value: ActualRecord)]] = [:]
        for (inputOrder, actual) in locked.enumerated() {
            groupedLocked[actual.source.rawValue, default: []].append(
                (inputOrder, actual)
            )
        }
        let indexes = groupedLocked.mapValues { values in
            ActivityClassificationIntervalIndex(values, span: classificationSpan)
        }
        var matchedLockedIndices = Set<Int>()
        var merged = fresh.map { candidate in
            guard candidate.source.usesAutomaticClassification else {
                return candidate
            }
            var value = candidate
            value.isClassificationLocked = true
            value.lockReason = value.lockReason ?? value.defaultLockReason
            var bestMatch: (record: ActualRecord, overlap: TimeInterval, inputOrder: Int)?
            indexes[candidate.source.rawValue]?.forEachCandidate(
                overlapping: classificationSpan(candidate),
                inspectionCount: &inspectionCount
            ) { previous, inputOrder in
                guard overlapRatio(previous, candidate) >= 0.2 else { return }
                matchedLockedIndices.insert(inputOrder)
                let overlap = overlapDuration(previous, candidate)
                if bestMatch == nil
                    || overlap > bestMatch!.overlap
                    || (
                        overlap == bestMatch!.overlap
                            && inputOrder < bestMatch!.inputOrder
                    ) {
                    bestMatch = (previous, overlap, inputOrder)
                }
            }
            guard let previous = bestMatch?.record else {
                return value
            }
            guard ![CalendarTitleClassification.freshWins, WorkBreakPattern.freshWins, RestaurantMealActualEngine.freshWins, AppleWatchSensorActivityEngine.freshWins].contains(where: { $0(previous, candidate) }),
                  !shouldAdoptFreshDestinationClassification(previous: previous, candidate: candidate) else {
                return value
            }
            value.categoryID = previous.categoryID
            value.title = previous.title
            value.behavior = previous.behavior
            if previous.manuallyCorrected { value.manuallyCorrected = true }
            if ActualRecord.userOwned(previous) { value.lockReason = .user }
            return value
        }
        let retained = locked.enumerated().compactMap { inputOrder, previous in
            matchedLockedIndices.contains(inputOrder) ? nil : previous
        }
        merged.append(contentsOf: retained)
        return merged.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func shouldAdoptFreshDestinationClassification(
        previous: ActualRecord,
        candidate: ActualRecord
    ) -> Bool {
        // 등록 장소(회사·학교·운동)에서 새로 판정한 기록은 예전 자동 '머무름·휴식·활동·일상'을 대신한다(WRK1029A02).
        // 전에는 이름이 정확히 "머무름"일 때만 바꿔서, 하루 전에 잠긴 '집에서 휴식' 조각이 업무를 계속 덮었다.
        let genericPrevious = previous.behavior == StationaryContextKind.unknownStay.rawValue
            || ["activity", "rest", "routine"].contains(previous.categoryID)
        guard previous.source == .location,
              candidate.source == .location,
              !previous.manuallyCorrected,
              genericPrevious,
              let behavior = candidate.behavior.flatMap(
                  StationaryContextKind.init(rawValue:)
              ),
              behavior != .unknownStay,
              candidate.evidence.contains(where: {
                  $0.hasPrefix("자주가는 곳:")
              }) else {
            return false
        }
        return true
    }

    static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return mergingLockedTravel(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
    }

    static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = mergingLockedTravel(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount ?? candidateInspectionCount
        return result
    }

    static func isRememberedOnlySubway(_ segment: TravelSegment) -> Bool {
        segment.mode == .subway && segment.isConfirmed && segment.evidence.contains("사용자 확인 기억")
            && segment.subwayRoute.map(SubwayStationCatalog.isValid) != true
    }

    private static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan,
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        let locked = existing.filter {
            $0.isClassificationLocked
                && $0.span.intersection(with: inside) != nil
        }
        let index = ActivityClassificationIntervalIndex(
            locked.enumerated().map { ($0.offset, $0.element) },
            span: \TravelSegment.span
        )
        var matchedLockedIndices = Set<Int>()
        var merged = fresh.map { candidate in
            var value = candidate
            var bestMatch: (segment: TravelSegment, overlap: TimeInterval, inputOrder: Int)?
            index.forEachCandidate(
                overlapping: candidate.span,
                inspectionCount: &inspectionCount
            ) { previous, inputOrder in
                guard overlapRatio(previous.span, candidate.span) >= 0.2 else {
                    return
                }
                matchedLockedIndices.insert(inputOrder)
                let overlap = overlapDuration(previous.span, candidate.span)
                if bestMatch == nil
                    || overlap > bestMatch!.overlap
                    || (
                        overlap == bestMatch!.overlap
                            && inputOrder < bestMatch!.inputOrder
                    ) {
                    bestMatch = (previous, overlap, inputOrder)
                }
            }
            guard let previous = bestMatch?.segment else {
                value.isClassificationLocked = true
                return value
            }
            let isResolvedSubway = candidate.mode == .subway
                && candidate.subwayRoute.map(SubwayStationCatalog.isValid) == true
            let previousSubwayIsValidated = previous.mode != .subway
                || previous.isConfirmed
                || previous.subwayRoute.map(SubwayStationCatalog.isValid) == true
            // 새 판정이 고도 변화가 없어 지하철을 뺐으면 잠긴 자동 지하철을 물려받지 않는다(SUB1029A01).
            // 새 판정이 고신뢰 자동차(차량 모션·속도)여도 잠긴 자동 지하철을 물려받지 않는다(EXP1029A01 — 오늘 아침 자차 출근).
            // 탑승·하차역 노선 없이 기억으로만 확정된 지하철은 어떤 새 판정에도 넘긴다(PAW1102A03).
            let rejectsLockedSubway = Self.isRememberedOnlySubway(previous)
                || (previous.mode == .subway && !previous.isConfirmed
                    && (candidate.evidence.contains(TravelModeClassifier.noAltitudeChangeEvidence)
                        || TravelModeClassifier.isMotionBackedCar(candidate)))
            // 이어폰을 차로 본 옛 확정은 새 판정이 그 근거를 다시 찾지 못하면 물려받지 않는다(SUB1111A01).
            if previousSubwayIsValidated, !candidate.isConfirmed, !isResolvedSubway, !rejectsLockedSubway,
               !CarAudioTravelConfirmation.dropsStaleMatch(previous, for: candidate),
               UnobservedAppSpans.inheritsMode(from: previous, to: candidate) {
                value.mode = previous.mode
                value.subwayRoute = previous.subwayRoute ?? value.subwayRoute
                value.isConfirmed = previous.isConfirmed
            }
            value.isClassificationLocked = true
            return value
        }
        let retained = locked.enumerated().compactMap { inputOrder, previous in
            let validatedSubway = previous.mode != .subway
                || previous.isConfirmed
                || previous.subwayRoute.map(SubwayStationCatalog.isValid) == true
            return validatedSubway && !isRememberedOnlySubway(previous)
                && !matchedLockedIndices.contains(inputOrder) && !UnobservedAppSpans.isSuperseded(previous, by: fresh)
                ? UnobservedAppSpans.repairedLock(previous)
                : nil
        }
        merged.append(contentsOf: retained)
        return merged.sorted {
            if $0.span.start != $1.span.start {
                return $0.span.start < $1.span.start
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func overlapRatio(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> Double {
        let lhsSpan = classificationSpan(lhs)
        let rhsSpan = classificationSpan(rhs)
        return overlapDuration(lhsSpan, rhsSpan)
            / max(1, min(lhsSpan.duration, rhsSpan.duration))
    }

    private static func overlapDuration(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> TimeInterval {
        overlapDuration(classificationSpan(lhs), classificationSpan(rhs))
    }

    private static func classificationSpan(_ actual: ActualRecord) -> TimeSpan {
        TimeSpan(
            start: actual.startedAt,
            end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
        )
    }

    private static func overlapDuration(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> TimeInterval {
        lhs.intersection(with: rhs)?.duration ?? 0
    }

    private static func overlapRatio(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Double {
        overlapDuration(lhs, rhs) / max(1, min(lhs.duration, rhs.duration))
    }
}

/// Replaces this projection's automatic rows without letting its previous output block regeneration.
enum PlaceActivityRefreshEngine {
    static func merge(existing: [ActualRecord], candidates: [ActualRecord],
        inside span: TimeSpan, suppressedIDs: Set<UUID> = []) -> [ActualRecord] {
        let protectedIDs = Set(existing.filter {
            AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.placeActivity) && $0.manuallyCorrected
        }.map(\.id))
        let blockers = existing.filter {
            $0.source.usesAutomaticClassification
                && (!AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.placeActivity) || $0.manuallyCorrected)
                && ($0.categoryID != "unconfirmed" || $0.manuallyCorrected)
                && $0.span(asOf: span.end).intersection(with: span) != nil
        }
        let fresh = candidates.filter { candidate in
            let candidateSpan = candidate.span(asOf: span.end)
            return !protectedIDs.contains(candidate.id) && !suppressedIDs.contains(candidate.id)
                && !blockers.contains {
                    ($0.span(asOf: span.end).intersection(with: candidateSpan)?.duration ?? 0)
                        >= candidateSpan.duration * 0.5
                }
        }
        return existing.filter {
            !AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.placeActivity) || protectedIDs.contains($0.id)
                || $0.span(asOf: span.end).intersection(with: span) == nil
        } + fresh
    }
}
