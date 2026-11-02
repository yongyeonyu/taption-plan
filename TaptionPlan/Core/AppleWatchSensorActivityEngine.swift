import Foundation
import TaptionPlanEngine

enum AppleWatchSensorActivityEngine {
    static func upserting(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        linkedPlan: PlanRecord?,
        atHome: Bool = false
    ) -> [ActualRecord] {
        if summary.isAmbient == true {
            return upsertingAmbientActivity(
                summary,
                into: existing,
                atHome: atHome
            )
        }
        let previous = existing.first {
            $0.id == summary.sessionID
                && ($0.source == .healthKit || $0.source == .appleWatch)
        }
        let segments = summary.behaviorSegments ?? []
        let planID = linkedPlan?.id ?? summary.linkedPlanID ?? previous?.planID
        let behaviorTitle = summary.behavior?.title
            ?? "Apple Watch \(summary.workoutKind.title)"
        var evidence = summary.behaviorEvidence ?? []
        if evidence.isEmpty {
            evidence = ["Apple Watch 센서 청크"]
        }
        evidence.append(AutomaticRecordTimelineEngine.watchWorkoutEvidence)
        if summary.latestHeartRate != nil {
            evidence.append("심박수")
        }
        if summary.stepCount != nil {
            evidence.append("걸음·거리")
        }
        if !segments.isEmpty {
            let segmentIDs = Set(segments.map(\.id))
            let kept = existing.filter { actual in
                guard actual.source == .appleWatch else { return true }
                if actual.id == summary.sessionID { return false }
                guard actual.sensorChunkID == summary.sessionID else {
                    return true
                }
                return !segmentIDs.contains(actual.id)
            }
            let records = segments.map { segment in
                let categoryID: String = {
                    if segment.behavior.isMovement { return "movement" }
                    if segment.behavior == .sleep { return "sleep" }
                    return linkedPlan?.categoryID == "sleep"
                        || summary.linkedCategoryID == "sleep"
                        ? "sleep"
                        : "activity"
                }()
                let title = linkedPlan?.title
                    ?? summary.linkedPlanTitle
                    ?? segment.behavior.title
                let segmentEvidence = Array(
                    Set(evidence + segment.evidence + ["2.56초 IMU 창"])
                ).sorted()
                let previousSegment = existing.first { $0.id == segment.id }
                let frozenCategory = previousSegment.flatMap { previous in
                    previous.isClassificationLocked
                        ? previous.categoryID
                        : nil
                }
                let frozenTitle = previousSegment.flatMap { previous in
                    previous.isClassificationLocked ? previous.title : nil
                }
                let frozenBehavior = previousSegment.flatMap { previous in
                    previous.isClassificationLocked ? previous.behavior : nil
                }
                return ActualRecord(
                    id: segment.id,
                    planID: planID,
                    title: frozenTitle ?? title,
                    categoryID: frozenCategory ?? categoryID,
                    startedAt: segment.startedAt,
                    endedAt: segment.endedAt,
                    source: .appleWatch,
                    confidence: ConfidenceLevel(
                        score: segment.confidenceScore
                    ),
                    createdAt: previousSegment?.createdAt
                        ?? segment.startedAt,
                    behavior: frozenBehavior ?? segment.behavior.rawValue,
                    evidence: segmentEvidence,
                    sensorChunkID: summary.sessionID,
                    modelVersion: segment.modelVersion
                )
            }
            return (kept + records).sorted {
                $0.startedAt < $1.startedAt
            }
        }

        // Keep the existing window records when a final short chunk has no
        // complete 2.56-second window yet.
        if existing.contains(where: {
            $0.source == .appleWatch
                && $0.sensorChunkID == summary.sessionID
                && $0.id != summary.sessionID
        }) {
            return existing.sorted { $0.startedAt < $1.startedAt }
        }
        let title = linkedPlan?.title
            ?? summary.linkedPlanTitle
            ?? behaviorTitle
        let categoryID: String = {
            if summary.behavior?.isMovement == true { return "movement" }
            if summary.behavior == .sleep { return "sleep" }
            return linkedPlan?.categoryID == "sleep"
                || summary.linkedCategoryID == "sleep"
                ? "sleep"
                : "activity"
        }()
        let confidence = summary.behaviorConfidenceScore.map {
            ConfidenceLevel(score: $0)
        } ?? (summary.accelerometerSampleCount > 0 ? .high : .medium)
        let record = ActualRecord(
            id: summary.sessionID,
            planID: planID,
            title: previous?.isClassificationLocked == true
                ? previous?.title ?? title
                : title,
            categoryID: previous?.isClassificationLocked == true
                ? previous?.categoryID ?? categoryID
                : categoryID,
            startedAt: summary.startedAt,
            endedAt: max(summary.startedAt, summary.endedAt),
            source: .appleWatch,
            confidence: confidence,
            createdAt: previous?.createdAt ?? summary.startedAt,
            behavior: previous?.isClassificationLocked == true
                ? previous?.behavior
                : summary.behavior?.rawValue,
            evidence: Array(Set(evidence)).sorted(),
            sensorChunkID: summary.sessionID,
            modelVersion: summary.behaviorModelVersion
                ?? WatchBehaviorClassifier.rulesVersion
        )
        return (
            existing.filter { $0.id != summary.sessionID }
                + [record]
        ).sorted { $0.startedAt < $1.startedAt }
    }

    private static func upsertingAmbientActivity(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        atHome: Bool
    ) -> [ActualRecord] {
        let previous = existing.first {
            $0.id == summary.sessionID && $0.source == .appleWatch
        }
        guard atHome, sustainedMotion(summary) else {
            return existing.sorted { $0.startedAt < $1.startedAt }
        }
        if var confirmed = previous, confirmed.manuallyCorrected {
            confirmed.endedAt = max(
                confirmed.endedAt ?? confirmed.startedAt,
                summary.endedAt
            )
            return (
                existing.filter { $0.id != summary.sessionID } + [confirmed]
            ).sorted { $0.startedAt < $1.startedAt }
        }

        let behavior: WatchBehaviorKind = switch summary.behavior {
        case .showering, .brushingTeeth, .eating, .typing, .housework:
            summary.behavior ?? .housework
        default:
            .housework
        }

        var evidence = summary.behaviorEvidence ?? []
        evidence.append("Apple Watch 가속도 원시 기록")
        evidence.append("집 위치 내 지속 움직임")
        if let standardDeviation = summary.accelerometerStandardDeviationG {
            evidence.append(String(format: "가속도 변동 %.2fg", standardDeviation))
        }
        let record = ActualRecord(
            id: summary.sessionID,
            planID: nil,
            routineID: nil,
            title: behavior.title,
            categoryID: behavior == .sleep ? "sleep" : "activity",
            startedAt: previous?.startedAt ?? summary.startedAt,
            endedAt: max(previous?.endedAt ?? summary.startedAt, summary.endedAt),
            source: .appleWatch,
            confidence: summary.behaviorConfidenceScore.map {
                ConfidenceLevel(score: max(0.55, $0))
            } ?? .medium,
            createdAt: previous?.createdAt ?? summary.startedAt,
            behavior: behavior.rawValue,
            evidence: Array(Set(evidence)).sorted(),
            sensorChunkID: summary.sessionID,
            modelVersion: summary.behaviorModelVersion
                ?? WatchBehaviorClassifier.rulesVersion
        )
        return (
            existing.filter { $0.id != summary.sessionID }
                + [record]
        ).sorted { $0.startedAt < $1.startedAt }
    }

    /// 집안일 판정과 정지 구간 문맥 추론이 같은 기준을 쓰도록 공개한다.
    static func sustainedMotion(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        let duration = summary.endedAt.timeIntervalSince(summary.startedAt)
        guard duration >= 20, summary.accelerometerSampleCount >= 40 else {
            return false
        }
        let acceleration = max(
            summary.accelerometerStandardDeviationG ?? 0,
            summary.accelerometerMeanJerkGPerSecond ?? 0
        )
        let behaviorIsMotion = summary.behaviorSegments?.contains {
            switch $0.behavior {
            case .stationary, .standing, .sitting, .lying, .sleep, .unknown:
                false
            default:
                true
            }
        } ?? false
        return acceleration >= 0.018 || behaviorIsMotion
    }
}
