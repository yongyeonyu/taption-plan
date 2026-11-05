import Foundation
import TaptionPlanCore

/// 위젯이 직접 쓰는 계산. `PlanningEngine.swift` 전체를 위젯에서 컴파일하지 않게 따로 둔다(RFA1105A03).
struct QuickActionResult: Sendable {
    var plan: PlanRecord
    var actuals: [ActualRecord]
}

enum QuickActionEngine {
    static func start(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .running
        updated.updatedAt = date

        guard !actuals.contains(where: { $0.planID == plan.id && $0.endedAt == nil }) else {
            return QuickActionResult(plan: updated, actuals: actuals)
        }
        var values = actuals
        values.append(
            ActualRecord(
                planID: plan.id,
                title: plan.title,
                categoryID: plan.categoryID,
                startedAt: date,
                source: .timer
            )
        )
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func complete(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now,
        copyPlannedDurationWhenMissing: Bool = false
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .completed
        updated.updatedAt = date
        var values = actuals

        if let runningIndex = values.lastIndex(where: {
            $0.planID == plan.id && $0.endedAt == nil
        }) {
            values[runningIndex].endedAt = max(
                values[runningIndex].startedAt,
                date
            )
        } else if copyPlannedDurationWhenMissing {
            values.append(
                ActualRecord(
                    planID: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startedAt: plan.span.start,
                    endedAt: plan.span.end,
                    source: .manual
                )
            )
        }
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func postpone(
        plan: PlanRecord,
        by interval: TimeInterval = 30 * 60
    ) throws -> PlanRecord {
        try ScheduleEditEngine.move(plan, by: interval)
    }

    static func skip(
        plan: PlanRecord,
        at date: Date = .now
    ) -> PlanRecord {
        var value = plan
        value.status = .skipped
        value.updatedAt = date
        return value
    }

    static func moveToNextFreeTime(
        plan: PlanRecord,
        occupied: [TimeSpan],
        after date: Date = .now,
        searchLimit: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let duration = plan.span.duration
        guard duration > 0 else { throw PlanningError.invalidDuration }
        let limit = searchLimit ?? date.addingTimeInterval(14 * 86_400)
        let sorted = occupied
            .filter { $0.end > date }
            .sorted { $0.start < $1.start }
        var candidate = date

        for block in sorted {
            if candidate.addingTimeInterval(duration) <= block.start {
                break
            }
            if candidate < block.end {
                candidate = block.end
            }
            guard candidate.addingTimeInterval(duration) <= limit else {
                throw PlanningError.invalidDuration
            }
        }

        var value = plan
        value.span = TimeSpan(
            start: candidate,
            end: candidate.addingTimeInterval(duration)
        )
        value.updatedAt = .now
        return value
    }
}

/// Keeps measured movement records as raw evidence while showing one
/// canonical travel segment when the route inference covers that interval.
enum MovementDisplayEngine {
    static func reviewActuals(
        _ actuals: [ActualRecord],
        travel: [TravelSegment],
        calendarEvents: [CalendarRecord] = [],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let displayTravel = TravelSegmentPresentationEngine.consolidated(travel)
        let canonical = displayTravel.compactMap { segment -> ActualRecord? in
            let end = min(segment.span.end, date)
            guard end > segment.span.start else { return nil }
            let isConfirmedBySchedule = hasScheduledEvent(
                segment.span,
                in: calendarEvents
            )
            let isConfirmed = segment.isConfirmed
                || segment.confidence == .high
                || isConfirmedBySchedule
            let title = MovementPresentation.title(for: segment.mode)
            return ActualRecord(
                id: segment.id,
                planID: nil,
                title: isConfirmed ? title : "\(title) (미확인)",
                categoryID: isConfirmed ? "movement" : "unconfirmed",
                startedAt: segment.span.start,
                endedAt: end,
                source: .location,
                confidence: segment.confidence,
                createdAt: segment.span.start,
                behavior: segment.mode.rawValue,
                evidence: segment.evidence,
                // `isConfirmed` describes inference confidence, not a user
                // edit. Keep the manual-override flag reserved for explicit
                // corrections so coverage precedence stays truthful.
                manuallyCorrected: false
            )
        }
        return visibleActuals(
            actuals,
            travel: displayTravel,
            asOf: date
        ) + canonical
    }

    private static func hasScheduledEvent(
        _ span: TimeSpan,
        in events: [CalendarRecord]
    ) -> Bool {
        guard span.duration > 0 else { return false }
        return events.contains { event in
            !event.isAllDay
                && event.isCancelled != true
                && (event.span.intersection(with: span)?.duration ?? 0) > 0
        }
    }

    static func visibleActuals(
        _ actuals: [ActualRecord],
        travel: [TravelSegment],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let travelSpans = travel.map(\.span)
        return actuals.flatMap { actual -> [ActualRecord] in
            guard isMovementRecord(actual) else {
                return [actual]
            }
            // 사용자가 미확인 구간을 직접 확정한 기록은 파생 이동 결과가
            // 겹치더라도 숨기지 않는다. 원본은 그대로 두고 표시 우선권만 준다.
            guard !actual.manuallyCorrected, actual.source != .manual else {
                return [actual]
            }
            guard isReliable(actual) else { return [] }
            let span = actual.span(asOf: date)
            guard span.duration > 0 else { return [] }
            let remainders = ActualIntervalMergeEngine.subtracting(
                travelSpans,
                from: span
            )
            return remainders.enumerated().map { offset, remainder in
                var value = actual
                value.id = offset == 0
                    ? actual.id
                    : remainderID(actual.id, offset: offset)
                value.startedAt = remainder.start
                value.endedAt = remainder.end
                return value
            }
        }
    }

    /// 위치 체류에서 오래 이어진 보행 후보와 저신뢰 기본 후보는 이동 결과로
    /// 쓰지 않는다. 걷기·달리기·자전거는 사용자 교정, 운동 기록 또는 높은
    /// 신뢰도의 모션 판정이 있을 때만 남긴다.
    private static func isReliable(_ actual: ActualRecord) -> Bool {
        guard let mode = MovementPresentation.mode(for: actual) else {
            return actual.confidence != .low
        }
        guard [.walking, .running, .cycling].contains(mode) else { return true }
        if actual.manuallyCorrected || actual.source == .manual
            || actual.source == .timer {
            return true
        }
        guard actual.source != .location, actual.confidence == .high else {
            return false
        }
        if actual.source == .healthKit || actual.source == .appleWatch {
            return true
        }
        let evidence = actual.evidence.joined(separator: " ").lowercased()
        return actual.source == .motion
            || ["걸음", "cadence", "보폭", "pedometer", "gps", "core motion"]
                .contains { evidence.contains($0) }
    }

    private static func isMovementRecord(_ actual: ActualRecord) -> Bool {
        guard actual.categoryID != "appUsage" else { return false }
        return actual.categoryID == "movement"
            || MovementPresentation.mode(for: actual) != nil
    }

    private static func remainderID(_ id: UUID, offset: Int) -> UUID {
        StableRecordID.remainder(of: id, offset: offset)
    }
}

/// 잠든 시간은 정지 문맥에서도 "집에서 휴식"이나 "생활"로 잡힌다. 두 기록을
/// 그대로 두면 같은 시각을 정지 문맥과 수면이 각각 세어 하루 합계가 흐른
/// 시간을 넘는다.
/// 측정된 원본은 그대로 두고, 화면과 합계가 함께 읽는 값에서만 수면이 덮은
/// 만큼을 덜어 낸다. 수면이 통째로 덮은 기록만 사라지고 나머지는 남는다.
enum RestSleepDisplayEngine {
    static func isRest(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "rest"
            || actual.behavior == "cafe"
            || actual.behavior == "homeRest"
    }

    static func yieldsToSleep(_ actual: ActualRecord) -> Bool {
        isRest(actual)
            || actual.categoryID == "routine"
            || actual.behavior == "housework"
            || actual.behavior == WatchBehaviorKind.showering.rawValue
    }

    static func visibleActuals(
        _ actuals: [ActualRecord],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        guard actuals.contains(where: yieldsToSleep) else { return actuals }
        let sleepSpans = ActualIntervalMergeEngine.union(
            actuals
                .filter(AutomaticRecordTimelineEngine.isSleep)
                .map { $0.span(asOf: date) },
            mergeGap: 0
        )
        guard !sleepSpans.isEmpty else { return actuals }

        return actuals.flatMap { actual -> [ActualRecord] in
            guard yieldsToSleep(actual) else { return [actual] }
            let span = actual.span(asOf: date)
            guard span.duration > 0 else { return [actual] }
            let remainders = ActualIntervalMergeEngine.subtracting(
                sleepSpans,
                from: span
            )
            guard remainders != [span] else { return [actual] }
            return remainders.enumerated().map { offset, remainder in
                var trimmed = actual
                // 첫 조각이 원본 식별자를 지켜야 기록 상세로 넘어갈 수 있고,
                // 나머지 조각도 서로 다른 식별자라야 목록에서 지워지지 않는다.
                trimmed.id = offset == 0
                    ? actual.id
                    : remainderID(of: actual.id, offset: offset)
                trimmed.startedAt = remainder.start
                trimmed.endedAt = actual.endedAt == nil && remainder.end >= date
                    ? nil
                    : remainder.end
                return trimmed
            }
        }
    }

    /// 같은 기록을 다시 잘라도 같은 값이 나와야 화면 갱신마다 선택이 풀리지
    /// 않는다. 자동 기록의 안정된 식별자와 같은 방식으로 만든다.
    private static func remainderID(of id: UUID, offset: Int) -> UUID {
        StableRecordID.remainder(of: id, offset: offset)
    }
}

enum PlanningError: Error, Equatable {
    case missingPlan(UUID)
    case parentCycle
    case childOutsideParent
    case invalidDuration
    case fixedPlan
}

enum ActualRecordSuppressionEngine {
    static func visibleRecords(
        from records: [ActualRecord],
        suppressedIDs: Set<UUID>
    ) -> [ActualRecord] {
        records.filter { !suppressedIDs.contains($0.id) }
    }
}

enum AutomaticRecordTimelineEngine {
    static let healthWorkoutEvidence = "HealthKit 운동 기록"
    static let watchWorkoutEvidence = "Apple Watch 운동 세션"

    /// Device/HealthKit records are ground truth. Their timestamps and
    /// measured duration must never be changed by the plan editor or the
    /// routine progress slider.
    static func isImmutable(_ actual: ActualRecord) -> Bool {
        switch actual.source {
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        case .manual, .timer, .calendar, .photo:
            false
        }
    }

    static func isSleep(_ actual: ActualRecord) -> Bool {
        // 앱 이름은 임의의 낱말이라 제목만 보고 수면으로 오인하면 안 된다.
        if actual.categoryID == "appUsage" { return false }
        return actual.categoryID == "sleep"
            || actual.title.localizedCaseInsensitiveContains("수면")
            || actual.title.localizedCaseInsensitiveContains("취침")
            || actual.title.localizedCaseInsensitiveContains("sleep")
    }

    /// HealthKit의 HKWorkout과 Watch에서 직접 시작한 운동 세션만 운동으로
    /// 확정한다. 수동 계획이나 iPhone의 수동적 걷기 추정은 포함하지 않는다.
    static func isConfirmedWorkout(_ actual: ActualRecord) -> Bool {
        guard actual.source == .healthKit || actual.source == .appleWatch,
              !isSleep(actual) else {
            return false
        }
        if actual.categoryID == "exercise"
            || actual.behavior == WatchBehaviorKind.exercise.rawValue {
            return true
        }
        if actual.evidence.contains(healthWorkoutEvidence)
            || actual.evidence.contains(watchWorkoutEvidence) {
            return true
        }
        // 이전 Watch 빌드에는 운동 세션 표식이 없었다. 주기 수집으로 생긴
        // 집안일은 제외하고, 센서 세션이 있는 옛 기록만 호환한다.
        return actual.source == .appleWatch
            && actual.sensorChunkID != nil
            && actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:))?
                .isMovement == true
    }

    static func isRoutineOnlyCategory(_ categoryID: String) -> Bool {
        categoryID == "sleep" || categoryID == "activity"
    }

    static func linksOnlyToRoutine(_ actual: ActualRecord) -> Bool {
        isRoutineOnlyCategory(actual.categoryID)
    }

    static func activities(
        from actuals: [ActualRecord],
        inside span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        visibleThroughNow(actuals, asOf: asOf)
            .filter {
                ($0.source == .healthKit
                    || $0.source == .appleWatch
                    || $0.source == .motion
                    || $0.source == .location
                    || $0.source == .media
                    || $0.source == .call
                    || $0.source == .appUsage)
                    && $0.span(asOf: asOf).intersection(with: span) != nil
            }
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.span(asOf: asOf).end
                        < $1.span(asOf: asOf).end
                }
                return $0.startedAt < $1.startedAt
            }
    }

    /// 화면에 걸치는 기록만 잘라 낸다.  전체 기록을 먼저 복사한 뒤 걸러 내면
    /// 배율을 바꿀 때마다 보이지도 않는 기록까지 구조체를 새로 만든다.
    static func visibleThroughNow(
        _ actuals: [ActualRecord],
        intersecting span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        actuals.compactMap { actual in
            guard actual.startedAt < asOf,
                  actual.startedAt < span.end else { return nil }
            let observedEnd = min(actual.endedAt ?? asOf, asOf)
            guard max(actual.startedAt, observedEnd) > span.start else {
                return nil
            }
            var visible = actual
            if visible.endedAt == nil || visible.endedAt! > asOf {
                visible.endedAt = asOf
            }
            return visible
        }
    }

    /// Automatic records are observations, not forecasts.  Keep the source
    /// record immutable while clipping the copy used by timelines/widgets to
    /// the current instant.
    static func visibleThroughNow(
        _ actuals: [ActualRecord],
        asOf: Date = .now
    ) -> [ActualRecord] {
        actuals.compactMap { actual in
            guard actual.startedAt <= asOf else { return nil }
            var visible = actual
            if visible.endedAt == nil || visible.endedAt! > asOf {
                visible.endedAt = asOf
            }
            return visible
        }
    }
}

enum ScheduleEditEngine {
    static let dragSnap: TimeInterval = 15 * 60

    static func move(
        _ plan: PlanRecord,
        by delta: TimeInterval
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let snapped = (delta / dragSnap).rounded() * dragSnap
        var value = plan
        value.span = TimeSpan(
            start: plan.span.start.addingTimeInterval(snapped),
            end: plan.span.end.addingTimeInterval(snapped)
        )
        value.updatedAt = .now
        return value
    }

    static func resize(
        _ plan: PlanRecord,
        newStart: Date? = nil,
        newEnd: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let start = snap(newStart ?? plan.span.start)
        let end = snap(newEnd ?? plan.span.end)
        guard start < end else { throw PlanningError.invalidDuration }
        var value = plan
        value.span = TimeSpan(start: start, end: end)
        value.updatedAt = .now
        return value
    }

    private static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(
            timeIntervalSinceReferenceDate: (seconds / dragSnap).rounded() * dragSnap
        )
    }
}

/// Keeps raw movement intact while collapsing duplicate display segments.
enum TravelSegmentPresentationEngine {
    static func consolidated(
        _ segments: [TravelSegment]
    ) -> [TravelSegment] {
        TravelMode.allCases
            .flatMap { mode in
                consolidate(segments.filter { $0.mode == mode })
            }
            .sorted {
                $0.span.start == $1.span.start
                    ? $0.span.end < $1.span.end
                    : $0.span.start < $1.span.start
            }
    }

    static func isWorkoutWalking(
        _ segment: TravelSegment,
        actuals: [ActualRecord],
        asOf date: Date = .now
    ) -> Bool {
        segment.mode == .walking
            && isWorkoutTravel(segment, actuals: actuals, asOf: date)
    }

    static func isWorkoutTravel(
        _ segment: TravelSegment,
        actuals: [ActualRecord],
        asOf date: Date = .now
    ) -> Bool {
        guard segment.span.duration > 0,
              [.walking, .running, .cycling].contains(segment.mode) else {
            return false
        }
        return actuals.contains { actual in
            guard AutomaticRecordTimelineEngine.isConfirmedWorkout(actual),
                  MovementPresentation.mode(for: actual) == segment.mode,
                  let overlap = actual.span(asOf: date)
                    .intersection(with: segment.span) else {
                return false
            }
            return overlap.duration / segment.span.duration >= 0.5
        }
    }

    private static func consolidate(
        _ segments: [TravelSegment]
    ) -> [TravelSegment] {
        var result: [TravelSegment] = []
        for segment in segments.sorted(by: chronological) {
            guard let last = result.last,
                  segment.span.start <= last.span.end else {
                result.append(segment)
                continue
            }
            result[result.count - 1] = merged(last, segment)
        }
        return result
    }

    private static func merged(
        _ lhs: TravelSegment,
        _ rhs: TravelSegment
    ) -> TravelSegment {
        let preferred = isPreferred(rhs, over: lhs) ? rhs : lhs
        var value = preferred
        value.span = TimeSpan(
            start: min(lhs.span.start, rhs.span.start),
            end: max(lhs.span.end, rhs.span.end)
        )
        value.distanceMeters = max(lhs.distanceMeters, rhs.distanceMeters)
        value.confidence = confidenceRank(lhs.confidence)
            >= confidenceRank(rhs.confidence) ? lhs.confidence : rhs.confidence
        value.evidence = Array(Set(lhs.evidence + rhs.evidence)).sorted()
        value.isConfirmed = lhs.isConfirmed || rhs.isConfirmed
        value.fromPlaceID = lhs.span.start <= rhs.span.start
            ? lhs.fromPlaceID ?? rhs.fromPlaceID
            : rhs.fromPlaceID ?? lhs.fromPlaceID
        value.toPlaceID = lhs.span.end >= rhs.span.end
            ? lhs.toPlaceID ?? rhs.toPlaceID
            : rhs.toPlaceID ?? lhs.toPlaceID
        value.subwayRoute = preferred.subwayRoute
            ?? (preferred.id == lhs.id ? rhs.subwayRoute : lhs.subwayRoute)
        return value
    }

    private static func isPreferred(
        _ lhs: TravelSegment,
        over rhs: TravelSegment
    ) -> Bool {
        if lhs.isConfirmed != rhs.isConfirmed { return lhs.isConfirmed }
        let leftConfidence = confidenceRank(lhs.confidence)
        let rightConfidence = confidenceRank(rhs.confidence)
        if leftConfidence != rightConfidence {
            return leftConfidence > rightConfidence
        }
        if lhs.span.duration != rhs.span.duration {
            return lhs.span.duration > rhs.span.duration
        }
        if lhs.distanceMeters != rhs.distanceMeters {
            return lhs.distanceMeters > rhs.distanceMeters
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func confidenceRank(_ confidence: ConfidenceLevel) -> Int {
        switch confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private static func chronological(
        _ lhs: TravelSegment,
        _ rhs: TravelSegment
    ) -> Bool {
        lhs.span.start == rhs.span.start
            ? lhs.span.end < rhs.span.end
            : lhs.span.start < rhs.span.start
    }
}
