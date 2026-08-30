import Foundation

public enum ActivitySensorEvidenceFusion {
    public static let defaultMatchingWindow: TimeInterval = 2

    public static func fuse(
        _ evidence: [ActivitySensorEvidence],
        matchingWindow: TimeInterval = defaultMatchingWindow
    ) -> [ActivitySensorEvidence] {
        let ordered = evidence.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard ordered.contains(where: { $0.source == .appleWatch }) else {
            return ordered
        }

        var consumed = Set<UUID>()
        var result: [ActivitySensorEvidence] = []
        for candidate in ordered where !consumed.contains(candidate.id) {
            guard candidate.source != .combined else {
                result.append(candidate)
                consumed.insert(candidate.id)
                continue
            }
            let counterpartSource: ActivitySensorSource = candidate.source == .appleWatch ? .iPhone : .appleWatch
            let counterpart = ordered
                .filter {
                    !consumed.contains($0.id)
                        && $0.source == counterpartSource
                        && abs($0.timestamp.timeIntervalSince(candidate.timestamp)) <= max(0, matchingWindow)
                }
                .min {
                    let lhsDistance = abs($0.timestamp.timeIntervalSince(candidate.timestamp))
                    let rhsDistance = abs($1.timestamp.timeIntervalSince(candidate.timestamp))
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    return $0.id.uuidString < $1.id.uuidString
                }
            if let counterpart {
                let watch = candidate.source == .appleWatch ? candidate : counterpart
                let phone = candidate.source == .iPhone ? candidate : counterpart
                result.append(combined(phone: phone, watch: watch))
                consumed.insert(candidate.id)
                consumed.insert(counterpart.id)
            } else {
                result.append(candidate)
                consumed.insert(candidate.id)
            }
        }
        return result.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func combined(
        phone: ActivitySensorEvidence,
        watch: ActivitySensorEvidence
    ) -> ActivitySensorEvidence {
        let watchBehavior = watch.behaviorHint ?? watch.detailHint ?? watch.categoryHint
        let phoneBehavior = phone.behaviorHint ?? phone.detailHint ?? phone.categoryHint
        let sequence = [phone.sequence, watch.sequence].compactMap { $0 }.max()
        let confidence = [phone.confidence, watch.confidence].compactMap { $0 }.max()
        return ActivitySensorEvidence(
            id: ActivityStableID.uuid(seed: "combined|\(phone.id.uuidString)|\(watch.id.uuidString)"),
            timestamp: min(phone.timestamp, watch.timestamp),
            motion: watch.motion == .unknown ? phone.motion : watch.motion,
            speedMetersPerSecond: phone.speedMetersPerSecond ?? watch.speedMetersPerSecond,
            horizontalAccuracyMeters: phone.horizontalAccuracyMeters ?? watch.horizontalAccuracyMeters,
            isPreciseLocation: phone.isPreciseLocation || watch.isPreciseLocation,
            stepCount: watch.stepCount ?? phone.stepCount,
            screenIsOn: phone.screenIsOn ?? watch.screenIsOn,
            screenBrightness: phone.screenBrightness ?? watch.screenBrightness,
            categoryHint: watch.categoryHint ?? phone.categoryHint,
            detailHint: watch.detailHint ?? phone.detailHint,
            behaviorHint: watchBehavior ?? phoneBehavior,
            confidence: confidence,
            evidence: unique(phone.evidence + watch.evidence + ["Apple Watch + iPhone 조합"]),
            sequence: sequence,
            source: .combined
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct ActivityClassificationProjection: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let inputEvidence: [ActivitySensorEvidence]
    public let state: ActivityClassificationState
    public let majorCategoryIDs: [String]

    public init(
        engine: ActivityClassificationEngine = .init(),
        evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride] = []
    ) {
        version = Self.currentVersion
        inputEvidence = evidence
        let fused = ActivitySensorEvidenceFusion.fuse(evidence)
        let validMajorIDs = Set(engine.taxonomy.majors.map(\.id))
        let safeOverrides = overrides.map { override in
            guard validMajorIDs.contains(override.majorCategoryID) else {
                return ActivityClassificationOverride(
                    id: override.id,
                    span: override.span,
                    majorCategoryID: engine.taxonomy.majors.first?.id ?? "activity",
                    detailID: nil,
                    title: override.title,
                    behavior: override.behavior,
                    updatedAt: override.updatedAt,
                    isLocked: override.isLocked
                )
            }
            return override
        }
        state = engine.classifyState(fused, overrides: safeOverrides)
        var seen = Set<String>()
        majorCategoryIDs = state.segments.compactMap {
            seen.insert($0.majorCategoryID).inserted ? $0.majorCategoryID : nil
        }
    }
}
