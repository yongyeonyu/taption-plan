import Foundation
import TaptionPlanEngine

/// Turns the iPhone's passive Core Motion intervals into immutable activity
/// records. A HealthKit workout or an explicit tracking session wins when it
/// covers the same interval, so the activity lane never shows two copies of
/// one workout.
enum MotionActivityActualEngine {
    private struct CompetingActualIndexes: Sendable {
        private let stationary: TimeSpanValueIndex<TimeSpan>
        private let movement: TimeSpanValueIndex<TimeSpan>

        init(existing: [ActualRecord], asOf: Date) {
            var stationarySpans: [TimeSpan] = []
            var movementSpans: [TimeSpan] = []
            stationarySpans.reserveCapacity(existing.count)
            movementSpans.reserveCapacity(existing.count)

            for actual in existing {
                let span = actual.span(asOf: asOf)
                guard span.duration > 0 else { continue }
                if MotionActivityActualEngine.isCompetingAutomaticRecord(
                    actual,
                    against: .stationary
                ) {
                    stationarySpans.append(span)
                }
                if MotionActivityActualEngine.isCompetingAutomaticRecord(
                    actual,
                    against: .walking
                ) {
                    movementSpans.append(span)
                }
            }
            stationary = TimeSpanValueIndex(stationarySpans) { $0 }
            movement = TimeSpanValueIndex(movementSpans) { $0 }
        }

        func containsOverlap(
            with span: TimeSpan,
            minimumDuration: TimeInterval,
            motion: MotionKind,
            inspectionCount: inout Int?
        ) -> Bool {
            let index = motion == .stationary ? stationary : movement
            guard span.duration >= minimumDuration,
                  minimumDuration > 0 else {
                return false
            }
            return index.contains(
                overlapping: span,
                inspectionCount: &inspectionCount
            ) { _, overlap in
                overlap.duration >= minimumDuration
            }
        }
    }

    static func records(
        from activities: [MotionActivityRecord],
        existing: [ActualRecord],
        inside: TimeSpan,
        minimumDuration: TimeInterval = 30,
        protectedIDs: Set<UUID> = []
    ) -> [ActualRecord] {
        var inspectionCount: Int? = nil
        return records(
            from: activities,
            existing: existing,
            inside: inside,
            minimumDuration: minimumDuration,
            protectedIDs: protectedIDs,
            inspectionCount: &inspectionCount
        )
    }

    static func records(
        from activities: [MotionActivityRecord],
        existing: [ActualRecord],
        inside: TimeSpan,
        minimumDuration: TimeInterval = 30,
        candidateInspectionCount: inout Int
    ) -> [ActualRecord] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = records(
            from: activities,
            existing: existing,
            inside: inside,
            minimumDuration: minimumDuration,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private static func records(
        from activities: [MotionActivityRecord],
        existing: [ActualRecord],
        inside: TimeSpan,
        minimumDuration: TimeInterval,
        protectedIDs: Set<UUID> = [],
        inspectionCount: inout Int?
    ) -> [ActualRecord] {
        // 장소 문맥 기록(5분 이상·등록 장소)이 덮은 틈은 머문 것이라 잇지 않는다 (CLN1110A01).
        let stays = existing.filter { $0.source == .location }.map { $0.span(asOf: inside.end) }
        let mergedActivities = bridgingFragments(merged(activities, inside: inside), protectedIDs: protectedIDs, stays: stays)
            .filter { $0.activity.span.duration >= minimumDuration }
        guard !mergedActivities.isEmpty else { return [] }
        inspectionCount? += existing.count
        let existingIndex = CompetingActualIndexes(
            existing: existing,
            asOf: inside.end
        )
        return mergedActivities.compactMap { activity, id, mergeEvidence in
                guard let title = activity.motion.activityTitle else {
                    return nil
                }
                let covered = existingIndex.containsOverlap(
                    with: activity.span,
                    minimumDuration: min(
                        activity.span.duration * 0.5,
                        30
                    ),
                    motion: activity.motion,
                    inspectionCount: &inspectionCount
                )
                guard !covered else { return nil }
                return ActualRecord(
                    id: id,
                    planID: nil,
                    routineID: nil,
                    title: title,
                    categoryID: activity.motion.isMovement
                        ? "movement"
                        : "activity",
                    startedAt: activity.span.start,
                    endedAt: activity.span.end,
                    source: .motion,
                    confidence: activity.confidence,
                    createdAt: activity.span.start,
                    behavior: activity.motion.rawValue,
                    evidence: [
                        "iPhone Core Motion",
                        "행동 구간 \(Int(activity.span.duration))초",
                    ] + mergeEvidence,
                    modelVersion: AutomaticModelVersion.motion
                )
            }
    }

    private static func merged(
        _ activities: [MotionActivityRecord],
        inside: TimeSpan
    ) -> [MotionActivityRecord] {
        let clipped = activities.compactMap { activity -> MotionActivityRecord? in
            guard let span = activity.span.intersection(with: inside),
                  activity.motion != .unknown else { return nil }
            return MotionActivityRecord(
                id: activity.id,
                span: span,
                motion: activity.motion,
                confidence: activity.confidence
            )
        }.sorted { $0.span.start < $1.span.start }

        var result: [MotionActivityRecord] = []
        for activity in clipped {
            guard var last = result.last,
                  last.motion == activity.motion,
                  activity.span.start.timeIntervalSince(last.span.end) <= 30 else {
                result.append(activity)
                continue
            }
            last.span.end = max(last.span.end, activity.span.end)
            last.confidence = stronger(last.confidence, activity.confidence)
            result[result.count - 1] = last
        }
        return result
    }

    private static func isCompetingAutomaticRecord(
        _ actual: ActualRecord,
        against motion: MotionKind
    ) -> Bool {
        guard actual.source == .healthKit
                || actual.source == .appleWatch
                || actual.source == .location else {
            return false
        }
        // 장소 문맥 기록이 덮은 구간은 "정지·휴식" 으로 다시 만들지 않는다.
        // 대신 같은 시간에 걷기·달리기가 잡혔다면 그 기록은 남긴다.
        if actual.source == .location,
           let behavior = actual.behavior,
           StationaryContextKind(rawValue: behavior) != nil {
            return motion == .stationary
        }
        return actual.categoryID == "exercise"
            || actual.categoryID == "activity"
            || actual.title.localizedCaseInsensitiveContains("걷")
            || actual.title.localizedCaseInsensitiveContains("달리")
            || actual.title.localizedCaseInsensitiveContains("자전거")
            || actual.title.localizedCaseInsensitiveContains("러닝")
    }

    private static func stronger(
        _ lhs: ConfidenceLevel,
        _ rhs: ConfidenceLevel
    ) -> ConfidenceLevel {
        let rank: [ConfidenceLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    static func stableID(for activity: MotionActivityRecord) -> UUID {
        let key = [
            activity.motion.rawValue,
            String(Int(activity.span.start.timeIntervalSinceReferenceDate.rounded())),
            String(Int(activity.span.end.timeIntervalSinceReferenceDate.rounded()))
        ].joined(separator: "|")
        return StableRecordID.goldenMixedFNV(key)
    }
}
