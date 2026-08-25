import Foundation
import TaptionActivityEngine

struct TaptionActivityClassificationResult: Sendable {
    let state: ActivityClassificationState

    var segments: [ActivitySegment] { state.segments }

    var majorCategoryIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.majorCategoryID).inserted ? $0.majorCategoryID : nil }
    }
}

enum TaptionActivityEngineAdapter {
    static let engine = ActivityClassificationEngine()
    static let confirmedSleepModelVersion = "manual-confirmed-sleep-v1"

    static func classify(
        readings: [SensorReading],
        travel: [TravelSegment] = [],
        corrections: [UUID: ActivityCorrection] = [:],
        actuals: [ActualRecord] = []
    ) -> TaptionActivityClassificationResult {
        let overrides = activityOverrides(corrections: corrections, actuals: actuals)
        let state = engine.classifyState(
            evidence(from: readings, travel: travel),
            overrides: overrides
        )
        return TaptionActivityClassificationResult(state: state)
    }

    static func evidence(
        from readings: [SensorReading],
        travel: [TravelSegment] = []
    ) -> [ActivitySensorEvidence] {
        readings.map { reading in
            let travelSegment = travel.first { $0.span.contains(reading.timestamp) }
            let detailHint = travelSegment.map(detailID(for:))
            return ActivitySensorEvidence(
                id: reading.id,
                timestamp: reading.timestamp,
                motion: motion(for: reading.motion),
                speedMetersPerSecond: reading.speedMetersPerSecond,
                horizontalAccuracyMeters: reading.point?.horizontalAccuracy,
                isPreciseLocation: reading.locationFixQuality != .approximate,
                stepCount: reading.stepCount,
                screenIsOn: reading.screenIsOn,
                screenBrightness: reading.screenBrightness,
                categoryHint: travelSegment == nil ? nil : "movement",
                detailHint: detailHint,
                behaviorHint: reading.behavior,
                confidence: reading.behaviorConfidenceScore,
                evidence: reading.behaviorEvidence ?? [],
                sequence: reading.sequence
            )
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
        actuals.compactMap { actual in
            guard let correction = correction(for: actual, corrections: corrections) else { return nil }
            let start = correction.startedAt ?? actual.startedAt
            let fallbackEnd = actual.endedAt ?? start.addingTimeInterval(1)
            let end = max(start, correction.endedAt ?? fallbackEnd)
            let detailID = detailID(for: correction)
            return ActivityClassificationOverride(
                id: actual.id,
                span: ActivityTimeSpan(start: start, end: end),
                majorCategoryID: correction.categoryID,
                detailID: detailID,
                title: correction.title,
                behavior: correction.behavior,
                updatedAt: actual.createdAt
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
