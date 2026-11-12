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

    /// 이어진 묶음으로 보는 틈. 10분 묶음 사이의 조회 겹침·짧은 끊김은 잇는다.
    static let ambientJoinGap: TimeInterval = 90

    /// 평상시 묶음 하나를 집 안 활동 기록으로 반영한다(WSN1112A01).
    ///
    /// 예전에는 세션 ID 하나로 기록을 계속 늘려, 집에 있는 며칠이 「집안일」 기록 하나가 됐다.
    /// 이제 묶음마다 판정하고, 같은 행동이 바로 이어질 때만 앞 기록을 늘린다.
    private static func upsertingAmbientActivity(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        atHome: Bool
    ) -> [ActualRecord] {
        let recordID = TaptionWatchStableID.ambientActivityRecord(
            sessionID: summary.sessionID,
            sequence: summary.sequence
        )
        // 예전 세션 통짜 기록은 자동 잠금이 걸려 있어도 지운다. 손으로 고친 것만 남긴다.
        var records = existing.filter { actual in
            guard actual.source == .appleWatch, !ActualRecord.userOwned(actual) else {
                return true
            }
            return actual.id != summary.sessionID
        }
        let start = summary.startedAt
        let end = max(summary.startedAt, summary.endedAt)
        let verdict = WatchAmbientChunkInterpreter.interpret(
            duration: end.timeIntervalSince(start),
            sampleCount: summary.accelerometerSampleCount,
            standardDeviationG: summary.accelerometerStandardDeviationG,
            segments: summary.behaviorSegments ?? []
        )
        guard atHome, verdict.outcome == .mixedActivity else {
            records.removeAll {
                $0.id == recordID && $0.source == .appleWatch
                    && !ActualRecord.userOwned($0)
            }
            return records.sorted { $0.startedAt < $1.startedAt }
        }

        let specific: Set<WatchBehaviorKind> = [
            .showering, .brushingTeeth, .eating, .typing,
        ]
        let behavior: WatchBehaviorKind = {
            guard let kind = summary.behavior, specific.contains(kind),
                  (summary.behaviorConfidenceScore ?? 0) >= 0.55 else {
                return .housework
            }
            return kind
        }()
        let evidence = Array(Set(
            verdict.evidence + [
                "Apple Watch 가속도 원시 기록",
                "집 위치 내 지속 움직임",
            ]
        )).sorted()
        let modelVersion = summary.behaviorModelVersion
            ?? WatchBehaviorClassifier.rulesVersion

        let sameSession = records.indices.filter {
            records[$0].source == .appleWatch
                && records[$0].sensorChunkID == summary.sessionID
        }
        let touches: (ActualRecord) -> Bool = { actual in
            let actualEnd = actual.endedAt ?? actual.startedAt
            return start <= actualEnd.addingTimeInterval(ambientJoinGap)
                && end >= actual.startedAt.addingTimeInterval(-ambientJoinGap)
        }
        // 사용자가 고친 기록이 이 시간을 덮고 있으면 그대로 둔다.
        if sameSession.contains(where: {
            ActualRecord.userOwned(records[$0]) && touches(records[$0])
        }) {
            return records.sorted { $0.startedAt < $1.startedAt }
        }
        if let index = sameSession.first(where: {
            records[$0].behavior == behavior.rawValue && touches(records[$0])
        }) {
            records[index].startedAt = min(records[index].startedAt, start)
            records[index].endedAt = max(records[index].endedAt ?? start, end)
            // 근거는 합치지 않고 가장 최근 묶음의 값으로 바꾼다. 합치면 묶음마다 다른 값이 쌓인다.
            if end >= (records[index].endedAt ?? end) {
                records[index].evidence = evidence
                records[index].modelVersion = modelVersion
            }
            return records.sorted { $0.startedAt < $1.startedAt }
        }
        records.removeAll { $0.id == recordID }
        records.append(
            ActualRecord(
                id: recordID,
                planID: nil,
                routineID: nil,
                title: behavior.title,
                categoryID: "activity",
                startedAt: start,
                endedAt: end,
                source: .appleWatch,
                confidence: ConfidenceLevel(score: verdict.confidenceScore),
                createdAt: start,
                behavior: behavior.rawValue,
                evidence: evidence,
                sensorChunkID: summary.sessionID,
                modelVersion: modelVersion
            )
        )
        return records.sorted { $0.startedAt < $1.startedAt }
    }

    /// HealthKit 수면 기록은 예전에 잠긴 자동 분류(며칠짜리 「집안일」 등)를 물려받지 않는다.
    /// 사용자가 고친 분류만 남긴다(WSN1112A01).
    static func freshWins(previous: ActualRecord, candidate: ActualRecord) -> Bool {
        candidate.categoryID == "sleep"
            && candidate.modelVersion == "healthkit-sleep-v1"
            && previous.categoryID != "sleep"
            && !ActualRecord.userOwned(previous)
    }

    /// 집안일 판정과 정지 구간 문맥 추론이 같은 기준을 쓰도록 공개한다.
    static func sustainedMotion(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        let end = max(summary.startedAt, summary.endedAt)
        let outcome = WatchAmbientChunkInterpreter.interpret(
            duration: end.timeIntervalSince(summary.startedAt),
            sampleCount: summary.accelerometerSampleCount,
            standardDeviationG: summary.accelerometerStandardDeviationG,
            segments: summary.behaviorSegments ?? []
        ).outcome
        return outcome == .mixedActivity || outcome == .mostlyGait
    }
}
