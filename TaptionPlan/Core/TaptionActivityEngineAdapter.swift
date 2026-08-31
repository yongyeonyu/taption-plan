import Foundation
import TaptionPlanEngine

struct TaptionActivityClassificationResult: Sendable {
    let state: ActivityClassificationState

    var segments: [ActivitySegment] { state.segments }

    var majorCategoryIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.majorCategoryID).inserted ? $0.majorCategoryID : nil }
    }
}

struct TaptionSensorQualityProjection: Sendable {
    let readings: [SensorReading]
    let routeReadings: [SensorReading]
    let rejectionCounts: [String: Int]
}

enum TaptionActivityEngineAdapter {
    static let engine = ActivityClassificationEngine()
    static let confirmedSleepModelVersion = "manual-confirmed-sleep-v1"
    static let inferredGapModelVersion = "activity-gap-viterbi-v1"

    static func qualityProjection(
        from readings: [SensorReading]
    ) -> TaptionSensorQualityProjection {
        var projected = readings.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        var rejectionCounts: [String: Int] = [:]

        func apply(
            _ keyPath: WritableKeyPath<SensorReading, Double?>,
            label: String,
            range: ClosedRange<Double>,
            minimumDeviation: Double
        ) {
            let filter = TaptionRobustScalarFilter(configuration: .init(
                physicalRange: range,
                minimumAbsoluteDeviation: minimumDeviation
            ))
            let decisions = filter.decisions(for: projected.map { $0[keyPath: keyPath] })
            for decision in decisions where decision.reason != nil {
                projected[decision.index][keyPath: keyPath] = nil
                let reason = decision.reason?.rawValue ?? "unknown"
                rejectionCounts["\(label).\(reason)", default: 0] += 1
            }
        }

        apply(\.speedMetersPerSecond, label: "speed", range: 0...120, minimumDeviation: 0.25)
        apply(\.speedAccuracyMetersPerSecond, label: "speedAccuracy", range: 0...60, minimumDeviation: 0.25)
        apply(\.courseDegrees, label: "course", range: 0...360, minimumDeviation: 1)
        apply(\.courseAccuracyDegrees, label: "courseAccuracy", range: 0...180, minimumDeviation: 1)
        apply(\.relativeAltitudeMeters, label: "relativeAltitude", range: -12_000...12_000, minimumDeviation: 0.5)
        apply(\.pressureKilopascals, label: "pressure", range: 30...120, minimumDeviation: 0.05)
        apply(\.currentPaceSecondsPerMeter, label: "currentPace", range: 0.05...3_600, minimumDeviation: 0.05)
        apply(\.currentCadenceStepsPerSecond, label: "cadence", range: 0...5, minimumDeviation: 0.05)
        apply(\.averageActivePaceSecondsPerMeter, label: "activePace", range: 0.05...3_600, minimumDeviation: 0.05)
        apply(\.watchAccelerationStandardDeviationG, label: "accelerationStd", range: 0...20, minimumDeviation: 0.02)
        apply(\.watchAccelerationMeanJerkGPerSecond, label: "accelerationJerk", range: 0...100, minimumDeviation: 0.05)
        apply(\.behaviorConfidenceScore, label: "behaviorConfidence", range: 0...1, minimumDeviation: 0.02)

        return TaptionSensorQualityProjection(
            readings: projected,
            routeReadings: TaptionRouteEngineAdapter.filteredReadings(
                from: projected,
                includeLowConfidenceBoundaries: false
            ),
            rejectionCounts: rejectionCounts
        )
    }

    static func classify(
        readings: [SensorReading],
        travel: [TravelSegment] = [],
        corrections: [UUID: ActivityCorrection] = [:],
        actuals: [ActualRecord] = []
    ) -> TaptionActivityClassificationResult {
        let overrides = activityOverrides(corrections: corrections, actuals: actuals)
        let projection = ActivityClassificationProjection(
            engine: engine,
            evidence: evidence(from: readings, travel: travel),
            overrides: overrides
        )
        return TaptionActivityClassificationResult(state: projection.state)
    }

    static func evidence(
        from readings: [SensorReading],
        travel: [TravelSegment] = []
    ) -> [ActivitySensorEvidence] {
        readings.map { reading in
            let travelSegment = travel.first { $0.span.contains(reading.timestamp) }
            let detailHint = travelSegment.map(detailID(for:))
            let accuracy = reading.point?.horizontalAccuracy
            let hasValidatedPreciseFix = reading.gpsAvailable
                && accuracy.map { $0.isFinite && (0...150).contains($0) } == true
                && reading.locationFixQuality != .approximate
            return ActivitySensorEvidence(
                id: reading.id,
                timestamp: reading.timestamp,
                motion: motion(for: reading.motion),
                speedMetersPerSecond: reading.speedMetersPerSecond,
                horizontalAccuracyMeters: accuracy,
                isPreciseLocation: reading.locationFixQuality == .precise
                    || hasValidatedPreciseFix,
                stepCount: reading.stepCount,
                screenIsOn: reading.screenIsOn,
                screenBrightness: reading.screenBrightness,
                categoryHint: travelSegment == nil ? nil : "movement",
                detailHint: detailHint,
                behaviorHint: behaviorHint(
                    for: reading.behavior,
                    hasMovementAlgorithmResult: travelSegment != nil
                ),
                confidence: reading.behaviorConfidenceScore,
                evidence: reading.behaviorEvidence ?? [],
                sequence: reading.sequence,
                source: reading.sourceDevice == .appleWatch ? .appleWatch : .iPhone
            )
        }
    }

    static func inferredGapActuals(
        readings: [SensorReading],
        travel: [TravelSegment],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        let protected = actuals.filter { $0.modelVersion != inferredGapModelVersion }
        let gaps = ReviewCoverageEngine.unconfirmedRecords(
            actuals: protected,
            in: [span],
            asOf: span.end
        )
        guard !gaps.isEmpty else { return [] }
        let allEvidence = evidence(from: readings, travel: travel)
        let gapEngine = ActivityGapInferenceEngine()
        return gaps.flatMap { gap -> [ActualRecord] in
            let gapSpan = TimeSpan(
                start: gap.startedAt,
                end: gap.endedAt ?? gap.startedAt
            )
            guard gapSpan.duration > 0 else { return [] }
            let preceding = protected
                .filter { ($0.endedAt ?? $0.startedAt) <= gapSpan.start }
                .max { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
            let following = protected
                .filter { $0.startedAt >= gapSpan.end }
                .min { $0.startedAt < $1.startedAt }
            let inferred = gapEngine.infer(.init(
                span: .init(start: gapSpan.start, end: gapSpan.end),
                evidence: allEvidence,
                precedingAnchor: preceding.map(activityGapAnchor),
                followingAnchor: following.map(activityGapAnchor)
            ))
            return inferred.map { segment in
                ActualRecord(
                    id: segment.id,
                    planID: nil,
                    title: engine.taxonomy.detail(for: segment.detailID)?.title
                        ?? engine.taxonomy.major(for: segment.majorCategoryID)?.title
                        ?? "활동",
                    categoryID: segment.majorCategoryID,
                    startedAt: segment.span.start,
                    endedAt: segment.span.end,
                    source: .motion,
                    confidence: ConfidenceLevel(score: segment.confidence),
                    createdAt: createdAt,
                    behavior: segment.behavior,
                    evidence: segment.provenance,
                    modelVersion: inferredGapModelVersion
                )
            }
        }
    }

    static func confirmedSleepOverrides(
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [ActivityClassificationOverride] {
        activityOverrides(corrections: corrections, actuals: actuals)
            .filter(\.isSleep)
    }

    static func activityOverrides(
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [ActivityClassificationOverride] {
        actuals.compactMap { actual -> ActivityClassificationOverride? in
            let correction = correction(for: actual, corrections: corrections)
            guard correction != nil || actual.isClassificationLocked || actual.manuallyCorrected else {
                return nil
            }
            let start = correction?.startedAt ?? actual.startedAt
            let fallbackEnd = actual.endedAt ?? start.addingTimeInterval(1)
            let end = max(start, correction?.endedAt ?? fallbackEnd)
            let categoryID = correction?.categoryID ?? actual.categoryID
            let resolvedDetailID = correction.map { self.detailID(for: $0) }
                ?? engine.taxonomy.detail(majorID: categoryID, behavior: actual.behavior ?? "")?.id
                ?? engine.taxonomy.major(for: categoryID)?.details.first?.id
            return ActivityClassificationOverride(
                id: actual.id,
                span: ActivityTimeSpan(start: start, end: end),
                majorCategoryID: categoryID,
                detailID: resolvedDetailID,
                title: correction?.title ?? actual.title,
                behavior: correction?.behavior ?? actual.behavior,
                updatedAt: actual.createdAt,
                isLocked: actual.isClassificationLocked || actual.manuallyCorrected
            )
        }
    }

    static func applyingConfirmedSleepOverrides(
        to actuals: [ActualRecord],
        corrections: [UUID: ActivityCorrection]
    ) -> [ActualRecord] {
        applying(
            confirmedSleepOverrides(corrections: corrections, actuals: actuals),
            to: actuals
        )
    }

    static func confirmedSleepOverrides(
        _ spans: [TimeSpan]
    ) -> [ActivityClassificationOverride] {
        normalizedSleepSpans(spans).map { span in
            ActivityClassificationOverride(
                id: ActivityStableID.uuid(
                    seed: "confirmed-sleep|\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)"
                ),
                span: ActivityTimeSpan(start: span.start, end: span.end),
                majorCategoryID: "sleep",
                detailID: "sleep.core",
                title: "수면",
                behavior: "core",
                updatedAt: span.start
            )
        }
    }

    static func confirmedSleepActuals(
        _ spans: [TimeSpan],
        createdAt: Date = .now
    ) -> [ActualRecord] {
        normalizedSleepSpans(spans).map { makeConfirmedSleepActual($0, createdAt: createdAt) }
    }

    static func migratedConfirmedSleepSpans(
        existing: [TimeSpan],
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [TimeSpan] {
        let current = normalizedSleepSpans(existing)
        guard current.isEmpty else { return current }

        var candidates = corrections.values.compactMap { correction -> TimeSpan? in
            guard correction.categoryID == "sleep",
                  let start = correction.startedAt,
                  let end = correction.endedAt,
                  end > start else { return nil }
            return TimeSpan(start: start, end: end)
        }
        candidates += actuals.compactMap { actual -> TimeSpan? in
            guard actual.categoryID == "sleep",
                  actual.manuallyCorrected,
                  let end = actual.endedAt,
                  end > actual.startedAt else { return nil }
            return TimeSpan(start: actual.startedAt, end: end)
        }
        return normalizedSleepSpans(candidates)
    }

    static func applyingConfirmedSleepSpans(
        _ spans: [TimeSpan],
        to actuals: [ActualRecord],
        createdAt: Date = .now
    ) -> [ActualRecord] {
        let normalized = normalizedSleepSpans(spans)
        let withoutPreviousConfirmedSleep = actuals.filter {
            $0.modelVersion != confirmedSleepModelVersion
        }
        guard !normalized.isEmpty else { return withoutPreviousConfirmedSleep }
        let cut = applying(
            confirmedSleepOverrides(normalized),
            to: withoutPreviousConfirmedSleep
        )
        let preserved = cut.filter { actual in
            guard actual.categoryID == "sleep" else { return true }
            let actualSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            return !normalized.contains { actualSpan.intersection(with: $0) != nil }
        }
        let freshSleep = normalized.map { span in
            let existingCreatedAt = actuals.first(where: {
                $0.modelVersion == confirmedSleepModelVersion
                    && $0.startedAt == span.start
                    && $0.endedAt == span.end
            })?.createdAt
            return makeConfirmedSleepActual(
                span,
                createdAt: existingCreatedAt ?? createdAt
            )
        }
        return (preserved + freshSleep).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func applying(
        _ overrides: [ActivityClassificationOverride],
        to actuals: [ActualRecord]
    ) -> [ActualRecord] {
        actuals.flatMap { actual -> [ActualRecord] in
            guard actual.source != .manual else { return [actual] }
            let originalSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            let relevant = overrides.filter { override in
                let span = TimeSpan(start: override.span.start, end: override.span.end)
                return originalSpan.intersection(with: span) != nil
            }
            guard !relevant.isEmpty else { return [actual] }
            var cuts = Set([originalSpan.start, originalSpan.end])
            for override in relevant {
                let span = TimeSpan(start: override.span.start, end: override.span.end)
                guard let intersection = originalSpan.intersection(with: span) else { continue }
                cuts.insert(intersection.start)
                cuts.insert(intersection.end)
            }
            let points = cuts.sorted()
            guard points.count >= 2 else { return [actual] }
            return points.indices.dropLast().compactMap { index -> ActualRecord? in
                let start = points[index]
                let end = points[index + 1]
                guard start < end else { return nil }
                let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                let selected = relevant
                    .filter { $0.span.start <= midpoint && midpoint < $0.span.end }
                    .sorted { lhs, rhs in
                        if lhs.isSleep != rhs.isSleep { return lhs.isSleep }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    .first
                var value = actual
                value.id = stableRecordID(
                    originalID: actual.id,
                    start: start,
                    end: end,
                    override: selected
                )
                value.startedAt = start
                value.endedAt = end
                if let selected {
                    value.title = selected.title ?? value.title
                    value.categoryID = selected.majorCategoryID
                    value.behavior = selected.behavior ?? selected.detailID
                    value.confidence = .high
                    value.evidence = unique(value.evidence + ["사용자 확인"])
                    value.manuallyCorrected = true
                }
                return value
            }
        }
    }

    static func makeStableManualActual(
        span: TimeSpan,
        option: ActivityCorrectionOption,
        createdAt: Date = .now
    ) -> ActualRecord {
        let id = ActivityStableID.uuid(
            seed: [
                "manual",
                String(span.start.timeIntervalSince1970),
                String(span.end.timeIntervalSince1970),
                option.categoryID,
                option.behavior ?? "",
                option.title
            ].joined(separator: "|")
        )
        return ActualRecord(
            id: id,
            planID: nil,
            title: option.title,
            categoryID: option.categoryID,
            startedAt: span.start,
            endedAt: span.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: option.behavior,
            evidence: ["사용자 입력"],
            manuallyCorrected: true
        )
    }

    private static func correction(
        for actual: ActualRecord,
        corrections: [UUID: ActivityCorrection]
    ) -> ActivityCorrection? {
        if let direct = corrections[actual.id] { return direct }
        return corrections.values.sorted { lhs, rhs in
            let lhsStart = lhs.startedAt ?? .distantPast
            let rhsStart = rhs.startedAt ?? .distantPast
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return (lhs.endedAt ?? .distantPast) < (rhs.endedAt ?? .distantPast)
        }.first { correction in
            guard correction.startedAt != nil || correction.endedAt != nil else { return false }
            let correctionStart = correction.startedAt ?? actual.startedAt
            let correctionEnd = correction.endedAt
                ?? actual.endedAt
                ?? correctionStart.addingTimeInterval(1)
            let actualSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            return actualSpan.intersection(
                with: TimeSpan(start: correctionStart, end: correctionEnd)
            ) != nil
        }
    }

    private static func detailID(for correction: ActivityCorrection) -> String {
        if let behavior = correction.behavior {
            if correction.categoryID == "sleep" { return "sleep.\(behavior)" }
            if let detail = engine.taxonomy.detail(majorID: correction.categoryID, behavior: behavior) {
                return detail.id
            }
        }
        return engine.taxonomy.major(for: correction.categoryID)?.details.first?.id
            ?? "\(correction.categoryID).automatic"
    }

    private static func detailID(for segment: TravelSegment) -> String {
        switch segment.mode {
        case .walking: return "movement.walking"
        case .running: return "movement.running"
        case .cycling: return "movement.cycling"
        case .subway: return "movement.subway"
        case .bus: return "movement.bus"
        case .car: return "movement.car"
        case .taxi: return "movement.car"
        case .train: return "movement.subway"
        case .ship: return "movement.ship"
        case .airplane: return "movement.airplane"
        }
    }

    private static func activityGapAnchor(
        _ actual: ActualRecord
    ) -> ActivityGapAnchor {
        let behavior = actual.behavior
            ?? engine.taxonomy.major(for: actual.categoryID)?.details.first?.behavior
            ?? actual.categoryID
        let detail = engine.taxonomy.detail(
            majorID: actual.categoryID,
            behavior: behavior
        )?.id ?? engine.taxonomy.major(for: actual.categoryID)?.details.first?.id
            ?? "\(actual.categoryID).automatic"
        return ActivityGapAnchor(
            majorCategoryID: actual.categoryID,
            detailID: detail,
            behavior: behavior
        )
    }

    private static func motion(for value: MotionKind) -> ActivityMotion {
        switch value {
        case .stationary: return .stationary
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .automotive
        case .unknown: return .unknown
        }
    }

    private static func behaviorHint(
        for value: String?,
        hasMovementAlgorithmResult: Bool
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.localizedLowercase
        let movementBehaviors = [
            "walking", "running", "cycling", "automotive", "subway",
            "publictransit", "stairsup", "stairsdown", "elevator",
            "걷기", "걷", "달리기", "자전거", "자동차", "지하철",
            "대중교통", "계단", "엘리베이터"
        ]
        if movementBehaviors.contains(where: { normalized.contains($0) }) {
            return hasMovementAlgorithmResult ? value : nil
        }
        return value
    }

    private static func stableRecordID(
        originalID: UUID,
        start: Date,
        end: Date,
        override: ActivityClassificationOverride?
    ) -> UUID {
        guard start != end else { return originalID }
        let seed = [
            originalID.uuidString,
            String(start.timeIntervalSince1970),
            String(end.timeIntervalSince1970),
            override?.majorCategoryID ?? "original",
            override?.detailID ?? ""
        ].joined(separator: "|")
        return ActivityStableID.uuid(seed: seed)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizedSleepSpans(_ spans: [TimeSpan]) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        var result: [TimeSpan] = []
        for span in ordered {
            guard let previous = result.last, span.start <= previous.end else {
                result.append(span)
                continue
            }
            result[result.count - 1] = TimeSpan(
                start: previous.start,
                end: max(previous.end, span.end)
            )
        }
        return result
    }

    private static func makeConfirmedSleepActual(
        _ span: TimeSpan,
        createdAt: Date
    ) -> ActualRecord {
        let id = ActivityStableID.uuid(
            seed: "confirmed-sleep|\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)"
        )
        return ActualRecord(
            id: id,
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: "core",
            evidence: ["사용자 확인 수면"],
            modelVersion: confirmedSleepModelVersion,
            manuallyCorrected: true
        )
    }
}

/// Makes automatic major-category decisions durable without touching the
/// sensor archive. A refresh may produce a new span or more evidence, but a
/// stored automatic record keeps its previous category unless a registered
/// destination resolves an earlier unknown stay. Explicit activity corrections
/// remain the only user override.
enum ActivityClassificationLockEngine {
    static func lockingAutomaticClassifications(
        _ actuals: [ActualRecord]
    ) -> [ActualRecord] {
        actuals.map { actual in
            guard actual.source.usesAutomaticClassification else {
                return actual
            }
            var value = actual
            value.isClassificationLocked = true
            return value
        }
    }

    static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan
    ) -> [ActualRecord] {
        let locked = existing.filter { actual in
            actual.isClassificationLocked
                && actual.source.usesAutomaticClassification
                && actual.span(asOf: inside.end).intersection(with: inside) != nil
        }
        var merged = fresh.map { candidate in
            guard candidate.source.usesAutomaticClassification else {
                return candidate
            }
            var value = candidate
            value.isClassificationLocked = true
            let candidates = locked.filter { previous in
                previous.source == candidate.source
                    && overlapRatio(previous, candidate) >= 0.2
            }
            guard let previous = candidates.max(by: {
                overlapDuration($0, candidate)
                    < overlapDuration($1, candidate)
            }) else {
                return value
            }
            guard !shouldAdoptFreshDestinationClassification(
                previous: previous,
                candidate: candidate
            ) else {
                return value
            }
            value.categoryID = previous.categoryID
            value.title = previous.title
            value.behavior = previous.behavior
            if previous.manuallyCorrected {
                value.manuallyCorrected = true
            }
            return value
        }
        let retained = locked.filter { previous in
            !fresh.contains { candidate in
                candidate.source == previous.source
                    && overlapRatio(previous, candidate) >= 0.2
            }
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
        guard previous.source == .location,
              candidate.source == .location,
              !previous.manuallyCorrected,
              (
                  previous.behavior == StationaryContextKind.unknownStay.rawValue
                      || (
                          previous.categoryID == "activity"
                              && previous.title == "머무름"
                      )
              ),
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
        let locked = existing.filter {
            $0.isClassificationLocked
                && $0.span.intersection(with: inside) != nil
        }
        var merged = fresh.map { candidate in
            var value = candidate
            let matches = locked.filter {
                overlapRatio($0.span, candidate.span) >= 0.2
            }
            guard let previous = matches.max(by: {
                overlapDuration($0.span, candidate.span)
                    < overlapDuration($1.span, candidate.span)
            }) else {
                value.isClassificationLocked = true
                return value
            }
            if !candidate.isConfirmed {
                value.mode = previous.mode
                value.subwayRoute = previous.subwayRoute ?? value.subwayRoute
                value.isConfirmed = previous.isConfirmed
            }
            value.isClassificationLocked = true
            return value
        }
        let retained = locked.filter { previous in
            !fresh.contains {
                overlapRatio(previous.span, $0.span) >= 0.2
            }
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
        let lhsSpan = TimeSpan(
            start: lhs.startedAt,
            end: lhs.endedAt ?? lhs.startedAt.addingTimeInterval(1)
        )
        let rhsSpan = TimeSpan(
            start: rhs.startedAt,
            end: rhs.endedAt ?? rhs.startedAt.addingTimeInterval(1)
        )
        return overlapDuration(lhsSpan, rhsSpan)
            / max(1, min(lhsSpan.duration, rhsSpan.duration))
    }

    private static func overlapDuration(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> TimeInterval {
        let lhsSpan = TimeSpan(
            start: lhs.startedAt,
            end: lhs.endedAt ?? lhs.startedAt.addingTimeInterval(1)
        )
        let rhsSpan = TimeSpan(
            start: rhs.startedAt,
            end: rhs.endedAt ?? rhs.startedAt.addingTimeInterval(1)
        )
        return overlapDuration(lhsSpan, rhsSpan)
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
