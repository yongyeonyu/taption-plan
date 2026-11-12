import Foundation
import TaptionPlanEngine

enum AppleWatchSensorActivityEngine {
    static func upserting(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        linkedPlan: PlanRecord?,
        atHome: Bool = false,
        vitals: WatchChunkVitals? = nil
    ) -> [ActualRecord] {
        if summary.isAmbient == true {
            return upsertingAmbientActivity(
                summary,
                into: existing,
                atHome: atHome,
                vitals: vitals
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
        atHome: Bool,
        vitals: WatchChunkVitals?
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
        // 손목은 걸음 주기를 놓쳐도 HealthKit 걸음 수가 많으면 걷던 시간이다(WSN1112A02).
        let isWalkingBySteps = (vitals?.stepsPerMinute ?? 0)
            >= WatchChunkVitals.walkingStepsPerMinute
        guard atHome, verdict.outcome == .mixedActivity, !isWalkingBySteps else {
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
                return vitals?.isExerciseLevel == true ? .exercise : .housework
            }
            return kind
        }()
        let evidence = Array(Set(
            verdict.evidence + (vitals?.evidence ?? []) + [
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

/// 평상시 묶음 시간에 HealthKit에 들어와 있던 심박·걸음(WSN1112A02).
/// Watch가 따로 재지 않고, 시스템이 건강 앱으로 옮겨 둔 값만 읽는다. 없으면 판정은 가속도만으로 한다.
struct WatchChunkVitals: Equatable, Sendable {
    /// 10분 묶음의 걸음이 분당 이만큼이면 걷던 시간으로 본다.
    static let walkingStepsPerMinute = 50.0
    /// 「운동」으로 보는 심박: 이 값 이상이고 평소 낮은 심박보다 `exerciseRise` 이상 높을 때.
    static let exerciseHeartRate = 120.0
    static let exerciseRise = 45.0
    /// 이보다 긴 걸음 표본은 묶음에 나눠 넣기엔 너무 거칠다.
    static let maximumStepSampleDuration: TimeInterval = 30 * 60

    /// 평상시 요약은 세션 ID가 같으므로 묶음 번호까지 넣어 가른다.
    static func key(for summary: TaptionWatchSensorSummary) -> UUID {
        TaptionWatchStableID.ambientActivityRecord(
            sessionID: summary.sessionID, sequence: summary.sequence
        )
    }

    var averageHeartRate: Double?
    var heartRateSampleCount = 0
    /// 묶음 앞 몇 시간 심박의 낮은 쪽 4분의 1 지점. 표본이 모자라면 nil.
    var restingHeartRate: Double?
    var stepsPerMinute: Double?

    var isExerciseLevel: Bool {
        guard let average = averageHeartRate, heartRateSampleCount >= 2,
              average >= Self.exerciseHeartRate else { return false }
        guard let resting = restingHeartRate else { return false }
        return average - resting >= Self.exerciseRise
    }

    var evidence: [String] {
        var lines: [String] = []
        if let average = averageHeartRate {
            lines.append("심박 평균 \(Int(average.rounded()))bpm(표본 \(heartRateSampleCount)개)")
        }
        if let resting = restingHeartRate {
            lines.append("평소 낮은 심박 \(Int(resting.rounded()))bpm")
        }
        if let steps = stepsPerMinute {
            lines.append("걸음 분당 \(Int(steps.rounded()))")
        }
        return lines
    }

    static func measured(
        in span: TimeSpan,
        records: [HealthKitSampleRecord]
    ) -> WatchChunkVitals? {
        let usable = records.filter { !$0.userEntered && $0.numericValue?.isFinite == true }
        let heartRates = usable.filter {
            $0.typeIdentifier == "HKQuantityTypeIdentifierHeartRate"
                && (30...240).contains($0.numericValue ?? 0)
        }
        let inside = heartRates.filter { span.contains($0.startDate) }
            .compactMap(\.numericValue)
        let before = heartRates.filter { $0.startDate < span.start }
            .compactMap(\.numericValue).sorted()
        var vitals = WatchChunkVitals()
        if !inside.isEmpty {
            vitals.averageHeartRate = inside.reduce(0, +) / Double(inside.count)
            vitals.heartRateSampleCount = inside.count
        }
        if before.count >= 12 {
            vitals.restingHeartRate = before[before.count / 4]
        }
        vitals.stepsPerMinute = stepsPerMinute(in: span, records: usable)
        guard vitals.averageHeartRate != nil || vitals.stepsPerMinute != nil else {
            return nil
        }
        return vitals
    }

    /// iPhone과 Watch가 같은 걸음을 따로 적으므로 더하지 않는다. Watch 표본이 있으면 그것만,
    /// 없으면 출처별 합 가운데 가장 큰 값을 쓴다.
    private static func stepsPerMinute(
        in span: TimeSpan,
        records: [HealthKitSampleRecord]
    ) -> Double? {
        guard span.duration >= 60 else { return nil }
        var bySource: [String: Double] = [:]
        for record in records
        where record.typeIdentifier == "HKQuantityTypeIdentifierStepCount" {
            let length = record.endDate.timeIntervalSince(record.startDate)
            guard length <= maximumStepSampleDuration, let count = record.numericValue,
                  count >= 0 else { continue }
            let overlap = min(span.end, record.endDate)
                .timeIntervalSince(max(span.start, record.startDate))
            guard overlap > 0 || (length == 0 && span.contains(record.startDate)) else {
                continue
            }
            let share = length > 0 ? overlap / length : 1
            let isWatch = record.sourceProductType?.hasPrefix("Watch") == true
            let key = isWatch
                ? "watch"
                : (record.sourceBundleIdentifier ?? record.sourceName ?? "other")
            bySource[key, default: 0] += count * share
        }
        guard let steps = bySource["watch"] ?? bySource.values.max() else { return nil }
        return steps / (span.duration / 60)
    }
}
