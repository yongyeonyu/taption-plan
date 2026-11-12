import Foundation
import TaptionPlanCore

// 워치 원본 창 replay와 사용자 확인 기반 개인화. 아이폰 앱만 쓴다. (WatchSyncModels.swift에서 나눴다.)

/// Replays Watch raw windows on the device that owns the day projection. The
/// Watch's original guess remains the fallback for legacy summary-only data;
/// a raw chunk is required before a new fine-grained result is published.
enum WatchActivityRawReplayEngine {
    static let modelVersion = "watch-raw-replay-v1"

    static func replaying(
        summaries: [TaptionWatchSensorSummary],
        chunks: [TaptionWatchAccelerationChunk]
    ) -> [TaptionWatchSensorSummary] {
        summaries.map { summary in
            let matchingChunks = matchingChunks(for: summary, in: chunks)
            guard !matchingChunks.isEmpty else {
                return summary
            }
            return replaying(summary: summary, chunks: matchingChunks)
        }
    }

    static func replaying(
        summary: TaptionWatchSensorSummary,
        chunk: TaptionWatchAccelerationChunk
    ) -> TaptionWatchSensorSummary {
        replaying(summary: summary, chunks: [chunk])
    }

    private static func replaying(
        summary: TaptionWatchSensorSummary,
        chunks: [TaptionWatchAccelerationChunk]
    ) -> TaptionWatchSensorSummary {
        let samples = Dictionary(
            chunks
                .flatMap(\.samples)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
            .values
            .filter {
                $0.capturedAt >= summary.startedAt
                    && $0.capturedAt <= summary.endedAt
            }
            .map {
                WatchMotionSample(
                    capturedAt: $0.capturedAt,
                    acceleration: $0.acceleration,
                    rotationRate: nil,
                    gravity: nil
                )
            }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let first = samples.first, let last = samples.last else {
            return summary
        }
        let rawDuration = last.capturedAt.timeIntervalSince(first.capturedAt)
        guard samples.count >= 8, rawDuration >= 1.5 else {
            var preserved = summary
            preserved.behaviorEvidence = Array(Set(
                (summary.behaviorEvidence ?? [])
                    + [
                        "Apple Watch raw 보관됨",
                        "raw 표본 \(samples.count)개 (재생성 부족)",
                    ]
            )).sorted()
            return preserved
        }

        let fallback = WatchBehaviorClassifier.classify(
            input(for: summary, duration: rawDuration)
        )
        let segments = segments(from: samples, summary: summary)
        // 평상시 보관 표본은 5초에 하나라 2.56초 창이 서지 않는다. 그때 묶음 통계만으로 다시
        // 판정하면 Watch가 12.5Hz 창으로 낸 결과를 더 거친 값으로 덮는다(WSN1112A01).
        guard !segments.isEmpty || summary.behavior == nil else {
            var preserved = summary
            preserved.behaviorEvidence = Array(Set(
                (summary.behaviorEvidence ?? [])
                    + [
                        "Apple Watch raw 보관됨",
                        "raw 표본 \(samples.count)개 (창 재생성 불가)",
                    ]
            )).sorted()
            return preserved
        }
        let inference = WatchBehaviorClassifier.aggregate(
            segments,
            fallback: fallback
        )
        var replayed = summary
        replayed.behavior = inference.kind
        replayed.behaviorConfidenceScore = inference.confidenceScore
        replayed.behaviorEvidence = Array(Set(
            (summary.behaviorEvidence ?? [])
                + inference.evidence
                + ["Apple Watch raw 재생성", "raw 표본 \(samples.count)개"]
        )).sorted()
        replayed.behaviorModelVersion = Self.modelVersion
        replayed.behaviorSegments = segments.isEmpty
            ? summary.behaviorSegments
            : segments
        return replayed
    }

    static func hasRawEvidence(
        for summary: TaptionWatchSensorSummary,
        in chunks: [TaptionWatchAccelerationChunk]
    ) -> Bool {
        !matchingChunks(for: summary, in: chunks).isEmpty
    }

    private static func matchingChunks(
        for summary: TaptionWatchSensorSummary,
        in chunks: [TaptionWatchAccelerationChunk]
    ) -> [TaptionWatchAccelerationChunk] {
        chunks
            .filter { !$0.samples.isEmpty }
            .filter {
                let overlapStart = max($0.startedAt, summary.startedAt)
                let overlapEnd = min($0.endedAt, summary.endedAt)
                let isSessionMatch = $0.sessionID == summary.sessionID
                let isLegacyAmbientMatch = summary.isAmbient == true
                    && $0.sessionID == nil
                return overlapEnd > overlapStart
                    && (isSessionMatch || isLegacyAmbientMatch)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private static func input(
        for summary: TaptionWatchSensorSummary,
        duration: TimeInterval
    ) -> WatchBehaviorInput {
        WatchBehaviorInput(
            workoutKind: nil,
            duration: max(1, duration),
            accelerometerSampleCount: summary.accelerometerSampleCount,
            accelerometerStandardDeviationG:
                summary.accelerometerStandardDeviationG,
            accelerometerMeanJerkGPerSecond:
                summary.accelerometerMeanJerkGPerSecond,
            peakAccelerationG: summary.peakAccelerationG,
            peakRotationRateRadiansPerSecond:
                summary.peakRotationRateRadiansPerSecond,
            steps: summary.stepCount,
            distanceMeters: summary.distanceMeters,
            floorsAscended: summary.floorsAscended,
            floorsDescended: summary.floorsDescended,
            averageHeartRate: summary.averageHeartRate,
            gpsAvailable: !(summary.routePoints ?? []).isEmpty,
            gpsLossRatio: (summary.routePoints ?? []).isEmpty ? 1 : 0,
            altitudeDeltaMeters: summary.relativeAltitudeMeters
        )
    }

    private static func segments(
        from samples: [WatchMotionSample],
        summary: TaptionWatchSensorSummary
    ) -> [WatchBehaviorSegment] {
        guard let first = samples.first, let last = samples.last else {
            return []
        }
        var result: [WatchBehaviorSegment] = []
        var windowEnd = first.capturedAt.addingTimeInterval(
            WatchBehaviorWindowAnalyzer.windowDuration
        )
        while windowEnd <= last.capturedAt {
            let windowStart = windowEnd.addingTimeInterval(
                -WatchBehaviorWindowAnalyzer.windowDuration
            )
            let window = samples.filter {
                $0.capturedAt >= windowStart && $0.capturedAt <= windowEnd
            }
            if let features = WatchBehaviorWindowAnalyzer.features(from: window) {
                let inference = WatchBehaviorClassifier.classifyWindow(
                    features,
                    context: input(for: summary, duration: features.duration)
                )
                append(
                    inference,
                    startedAt: features.startedAt,
                    endedAt: features.endedAt,
                    to: &result
                )
            }
            windowEnd = windowEnd.addingTimeInterval(
                WatchBehaviorWindowAnalyzer.strideDuration
            )
        }
        return result
    }

    private static func append(
        _ inference: WatchBehaviorInference,
        startedAt: Date,
        endedAt: Date,
        to segments: inout [WatchBehaviorSegment]
    ) {
        if let index = segments.indices.last,
           segments[index].behavior == inference.kind,
           startedAt.timeIntervalSince(segments[index].endedAt)
                <= WatchBehaviorWindowAnalyzer.strideDuration * 1.5 {
            segments[index].endedAt = max(segments[index].endedAt, endedAt)
            segments[index].confidenceScore = max(
                segments[index].confidenceScore,
                inference.confidenceScore
            )
            segments[index].evidence = Array(Set(
                segments[index].evidence + inference.evidence
            )).sorted()
            return
        }
        segments.append(
            WatchBehaviorSegment(
                startedAt: startedAt,
                endedAt: endedAt,
                behavior: inference.kind,
                confidenceScore: inference.confidenceScore,
                evidence: inference.evidence,
                modelVersion: Self.modelVersion
            )
        )
    }
}

struct WatchActivityResolution: Sendable {
    var learnedBehavior: WatchBehaviorInference?
    var suggestion: TaptionWatchActivitySuggestion?
}

/// 애매한 생활 행동은 사용자에게 묻고, 같은 패턴이 세 번 이상 같은 답을
/// 얻은 뒤에만 자동 확정한다. 운동 세션처럼 Apple이 이미 확정한 기록은
/// 이 경로를 거치지 않는다.
enum WatchActivityPersonalizationEngine {
    static let modelVersion = "watch-personal-v1"
    private static let minimumLearningSamples = 3

    static func pattern(
        from summary: TaptionWatchSensorSummary,
        atHome: Bool
    ) -> WatchActivityPattern {
        let duration = max(1, summary.endedAt.timeIntervalSince(
            summary.startedAt
        ))
        return WatchActivityPattern(
            duration: duration,
            accelerationVariationG: summary.accelerometerStandardDeviationG,
            jerkGPerSecond: summary.accelerometerMeanJerkGPerSecond,
            peakRotationRate: summary.peakRotationRateRadiansPerSecond,
            stepsPerMinute: summary.stepCount.map {
                Double($0) / max(1, duration / 60)
            },
            averageHeartRate: summary.averageHeartRate,
            atHome: atHome,
            waterLockEnabled: summary.waterLockEnabled == true,
            observedBehavior: summary.behavior
        )
    }

    static func resolve(
        _ summary: TaptionWatchSensorSummary,
        atHome: Bool,
        learnedSamples: [WatchActivityPatternSample],
        now: Date = .now
    ) -> WatchActivityResolution {
        guard summary.isAmbient == true else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }
        let pattern = pattern(from: summary, atHome: atHome)
        if let learned = learnedBehavior(
            for: pattern,
            samples: learnedSamples
        ) {
            return WatchActivityResolution(
                learnedBehavior: learned,
                suggestion: nil
            )
        }
        guard isSustainedMotion(pattern) else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }

        let proposal: (
            behavior: WatchBehaviorKind,
            alternatives: [WatchBehaviorKind],
            score: Double,
            evidence: [String]
        )?
        if atHome && pattern.waterLockEnabled && pattern.duration >= 60 {
            proposal = (
                .showering,
                [.housework],
                0.72,
                ["집 위치", "Water Lock 켜짐", "지속적인 손목 움직임"]
            )
        } else if atHome && summary.behavior?.isMovement != true {
            proposal = (
                .housework,
                [.showering, .brushingTeeth],
                max(0.55, min(0.74, summary.behaviorConfidenceScore ?? 0.6)),
                ["집 위치", "지속적인 손목 움직임"]
            )
        } else if let behavior = summary.behavior,
                  [.brushingTeeth, .eating, .typing, .housework]
                    .contains(behavior),
                  (summary.behaviorConfidenceScore ?? 0) < 0.85 {
            proposal = (
                behavior,
                [],
                summary.behaviorConfidenceScore ?? 0.55,
                summary.behaviorEvidence ?? ["Apple Watch 센서 추정"]
            )
        } else {
            proposal = nil
        }
        guard let proposal else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }
        return WatchActivityResolution(
            learnedBehavior: nil,
            suggestion: TaptionWatchActivitySuggestion(
                sensorSessionID: summary.sessionID,
                generatedAt: now,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                proposedBehavior: proposal.behavior,
                alternativeBehaviors: proposal.alternatives,
                confidenceScore: proposal.score,
                evidence: proposal.evidence,
                pattern: pattern
            )
        )
    }

    static func learnedBehavior(
        for pattern: WatchActivityPattern,
        samples: [WatchActivityPatternSample]
    ) -> WatchBehaviorInference? {
        let nearby = samples.compactMap { sample -> (
            WatchActivityPatternSample, Double
        )? in
            guard sample.pattern.atHome == pattern.atHome,
                  sample.pattern.waterLockEnabled
                    == pattern.waterLockEnabled else { return nil }
            let value = distance(pattern, sample.pattern)
            return value <= 1.5 ? (sample, value) : nil
        }
        .sorted { $0.1 < $1.1 }
        .prefix(8)
        guard nearby.count >= minimumLearningSamples else { return nil }

        var votes: [WatchBehaviorKind: Double] = [:]
        for (sample, distance) in nearby {
            votes[sample.label, default: 0] += 1 / (0.15 + distance)
        }
        guard let winner = votes.max(by: { $0.value < $1.value }) else {
            return nil
        }
        let total = votes.values.reduce(0, +)
        let confidence = total > 0 ? winner.value / total : 0
        guard confidence >= 0.8 else { return nil }
        return WatchBehaviorInference(
            kind: winner.key,
            confidenceScore: min(0.95, confidence),
            evidence: ["사용자 확인 패턴 \(nearby.count)회"],
            modelVersion: modelVersion
        )
    }

    private static func isSustainedMotion(
        _ pattern: WatchActivityPattern
    ) -> Bool {
        guard pattern.duration >= 20 else { return false }
        return (pattern.accelerationVariationG ?? 0) >= 0.018
            || (pattern.jerkGPerSecond ?? 0) >= 0.018
            || (pattern.stepsPerMinute ?? 0) >= 8
    }

    private static func distance(
        _ lhs: WatchActivityPattern,
        _ rhs: WatchActivityPattern
    ) -> Double {
        var values: [Double] = []
        func add(_ a: Double?, _ b: Double?, scale: Double) {
            guard let a, let b else { return }
            values.append(min(2, abs(a - b) / scale))
        }
        add(lhs.accelerationVariationG, rhs.accelerationVariationG, scale: 0.04)
        add(lhs.jerkGPerSecond, rhs.jerkGPerSecond, scale: 0.25)
        add(lhs.peakRotationRate, rhs.peakRotationRate, scale: 2)
        add(lhs.stepsPerMinute, rhs.stepsPerMinute, scale: 40)
        add(lhs.averageHeartRate, rhs.averageHeartRate, scale: 35)
        if let left = lhs.observedBehavior, let right = rhs.observedBehavior,
           left != right {
            values.append(0.35)
        }
        return values.isEmpty
            ? (lhs.observedBehavior == rhs.observedBehavior ? 0 : 2)
            : values.reduce(0, +) / Double(values.count)
    }
}
