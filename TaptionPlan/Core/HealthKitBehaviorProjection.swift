import Foundation

enum HealthKitBehaviorProjectionEngine {
    static let modelVersion = "healthkit-behavior-v1"
    private static let minimumEstimateDuration: TimeInterval = 10 * 60
    private static let maximumSampleGap: TimeInterval = 5 * 60

    static func actuals(
        from records: [HealthKitSampleRecord],
        in span: TimeSpan
    ) -> [ActualRecord] {
        let explicit = mergeExplicit(records.compactMap {
            explicitActual(from: $0, in: span)
        })
        let estimates = continuousEstimates(from: records, in: span)
        var byID = [UUID: ActualRecord]()
        for actual in explicit + estimates {
            byID[actual.id] = actual
        }
        return byID.values.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func mergeExplicit(_ records: [ActualRecord])
        -> [ActualRecord]
    {
        let sorted = records.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [ActualRecord] = []
        for record in sorted {
            guard var previous = result.last,
                  previous.title == record.title,
                  previous.categoryID == record.categoryID,
                  previous.behavior == record.behavior,
                  record.startedAt <= (previous.endedAt ?? previous.startedAt)
                    .addingTimeInterval(5 * 60) else {
                result.append(record)
                continue
            }
            previous.endedAt = max(
                previous.endedAt ?? previous.startedAt,
                record.endedAt ?? record.startedAt
            )
            previous.createdAt = max(previous.createdAt, record.createdAt)
            previous.confidence = stronger(
                previous.confidence,
                record.confidence
            )
            previous.evidence = Array(
                Set(previous.evidence + record.evidence)
            ).sorted()
            result[result.count - 1] = previous
        }
        return result
    }

    private static func stronger(
        _ lhs: ConfidenceLevel,
        _ rhs: ConfidenceLevel
    ) -> ConfidenceLevel {
        let ranks: [ConfidenceLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (ranks[lhs] ?? 0) >= (ranks[rhs] ?? 0) ? lhs : rhs
    }

    private static func explicitActual(
        from record: HealthKitSampleRecord,
        in span: TimeSpan
    ) -> ActualRecord? {
        let identifier = record.typeIdentifier
        guard !identifier.contains("UserAnnotatedMedication"),
              !isDirectGroundTruth(identifier),
              record.startDate <= span.end,
              record.endDate >= span.start else {
            return nil
        }

        let presentation: (title: String, category: String, behavior: String,
                           confidence: ConfidenceLevel)?
        if identifier.contains("Dietary")
            || identifier == "HKCorrelationTypeIdentifierFood" {
            presentation = (
                "식사",
                "eating",
                "meal",
                record.userEntered ? .high : .medium
            )
        } else if identifier.contains("MedicationDoseEvent")
                    || identifier.contains("MedicationRecord") {
            presentation = (
                "투약",
                "health",
                "medication",
                record.userEntered ? .high : .medium
            )
        } else if identifier.contains("StateOfMind")
                    || identifier.contains("Mindful") {
            presentation = (
                "마음 기록",
                "health",
                "wellness",
                .high
            )
        } else if isHealthEvent(identifier) {
            presentation = (
                identifier.contains("Handwashing")
                    || identifier.contains("Toothbrushing")
                    ? "건강관리"
                    : "건강 기록",
                "health",
                healthBehavior(identifier),
                record.userEntered ? .high : .medium
            )
        } else {
            presentation = nil
        }
        guard let presentation else { return nil }

        let start = max(span.start, record.startDate)
        let sourceEnd = max(record.endDate, start.addingTimeInterval(10 * 60))
        let end = min(span.end, sourceEnd)
        guard end > start else { return nil }
        return ActualRecord(
            id: record.uuid,
            planID: nil,
            title: presentation.title,
            categoryID: presentation.category,
            startedAt: start,
            endedAt: end,
            source: .healthKit,
            confidence: presentation.confidence,
            createdAt: record.endDate,
            behavior: presentation.behavior,
            evidence: provenance(
                records: [record],
                rule: "explicit"
            ),
            modelVersion: modelVersion
        )
    }

    private static func continuousEstimates(
        from records: [HealthKitSampleRecord],
        in span: TimeSpan
    ) -> [ActualRecord] {
        let numeric = records.filter {
            $0.numericValue?.isFinite == true
                && continuousKind($0.typeIdentifier) != nil
        }
        return Dictionary(grouping: numeric, by: \.typeIdentifier)
            .flatMap { identifier, values in
                guard let kind = continuousKind(identifier),
                      let baseline = baseline(
                        for: values.filter { $0.endDate < span.start },
                        kind: kind
                      ) else {
                    return [ActualRecord]()
                }
                return clusters(
                    values,
                    kind: kind,
                    baseline: baseline,
                    in: span
                ).compactMap {
                    estimatedActual(
                        records: $0,
                        kind: kind,
                        baseline: baseline,
                        span: span
                    )
                }
            }
    }

    private enum ContinuousKind {
        case activity
        case meal
        case vitals

        var title: String {
            switch self {
            case .activity: "활동 추정"
            case .meal: "식사 추정"
            case .vitals: "생체 변화"
            }
        }

        var categoryID: String {
            switch self {
            case .activity: "activity"
            case .meal: "eating"
            case .vitals: "health"
            }
        }

        var behavior: String {
            switch self {
            case .activity: "activity-estimate"
            case .meal: "meal-estimate"
            case .vitals: "vitals"
            }
        }

        var minimumRelativeDeviation: Double {
            switch self {
            case .activity: 0.20
            case .meal: 0.15
            case .vitals: 0.05
            }
        }
    }

    private struct Baseline {
        let median: Double
        let mad: Double
        let enterDeviation: Double
        let exitDeviation: Double
    }

    private static func continuousKind(
        _ identifier: String
    ) -> ContinuousKind? {
        if identifier == "HKQuantityTypeIdentifierHeartRate"
            || identifier.contains("ActiveEnergyBurned")
            || identifier.contains("PhysicalEffort")
            || identifier.contains("AppleExerciseTime") {
            return .activity
        }
        if identifier.contains("BloodGlucose") {
            return .meal
        }
        if identifier.contains("RespiratoryRate")
            || identifier.contains("OxygenSaturation")
            || identifier.contains("Temperature")
            || identifier.contains("HeartRateVariability")
            || identifier.contains("PeripheralPerfusion") {
            return .vitals
        }
        return nil
    }

    private static func baseline(
        for records: [HealthKitSampleRecord],
        kind: ContinuousKind
    ) -> Baseline? {
        let values = records.compactMap { normalizedValue($0) }.sorted()
        let days = Set(records.map {
            Calendar(identifier: .gregorian).startOfDay(for: $0.startDate)
        })
        guard days.count >= 7, values.count >= 20,
              let median = median(values) else {
            return nil
        }
        let deviations = values.map { abs($0 - median) }.sorted()
        let mad = Self.median(deviations) ?? 0
        let floor = max(abs(median) * kind.minimumRelativeDeviation, 0.000_001)
        let enter = max(2.5 * mad, floor)
        let exit = max(1.5 * mad, floor * 0.6)
        return Baseline(
            median: median,
            mad: mad,
            enterDeviation: enter,
            exitDeviation: exit
        )
    }

    private static func clusters(
        _ records: [HealthKitSampleRecord],
        kind: ContinuousKind,
        baseline: Baseline,
        in span: TimeSpan
    ) -> [[HealthKitSampleRecord]] {
        let ordered = records.sorted { $0.startDate < $1.startDate }
        var result: [[HealthKitSampleRecord]] = []
        var current: [HealthKitSampleRecord] = []

        func finish() {
            guard let first = current.first, let last = current.last,
                  last.endDate.timeIntervalSince(first.startDate)
                    >= minimumEstimateDuration,
                  current.count >= 3 else {
                current.removeAll(keepingCapacity: true)
                return
            }
            result.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for record in ordered {
            guard let value = normalizedValue(record) else { continue }
            let deviation = kind == .vitals
                ? abs(value - baseline.median)
                : value - baseline.median
            if current.isEmpty {
                if deviation >= baseline.enterDeviation {
                    current = [record]
                }
                continue
            }
            let gap = record.startDate.timeIntervalSince(
                current.last?.endDate ?? record.startDate
            )
            if gap <= maximumSampleGap,
               deviation >= baseline.exitDeviation {
                current.append(record)
            } else {
                finish()
                if deviation >= baseline.enterDeviation {
                    current = [record]
                }
            }
        }
        finish()
        return result.filter { cluster in
            guard let first = cluster.first, let last = cluster.last else {
                return false
            }
            return first.startDate <= span.end && last.endDate >= span.start
        }
    }

    private static func estimatedActual(
        records: [HealthKitSampleRecord],
        kind: ContinuousKind,
        baseline: Baseline,
        span: TimeSpan
    ) -> ActualRecord? {
        guard let first = records.first, let last = records.last else {
            return nil
        }
        let start = max(span.start, first.startDate)
        let end = min(span.end, last.endDate)
        guard end.timeIntervalSince(start) >= minimumEstimateDuration else {
            return nil
        }
        let seed = records.map { $0.uuid.uuidString }.joined(separator: ".")
        let confidence: ConfidenceLevel = records.count >= 5 ? .medium : .low
        let baselineEvidence = String(
            format: "baseline median=%.4f MAD=%.4f",
            baseline.median,
            baseline.mad
        )
        return ActualRecord(
            id: stableUUID("\(kind.behavior).\(seed)"),
            planID: nil,
            title: kind.title,
            categoryID: kind.categoryID,
            startedAt: start,
            endedAt: end,
            source: .healthKit,
            confidence: confidence,
            createdAt: last.endDate,
            behavior: kind.behavior,
            evidence: provenance(
                records: records,
                rule: kind.behavior
            ) + [baselineEvidence],
            modelVersion: modelVersion
        )
    }

    private static func normalizedValue(
        _ record: HealthKitSampleRecord
    ) -> Double? {
        guard let value = record.numericValue else { return nil }
        if record.typeIdentifier.contains("ActiveEnergyBurned")
            || record.typeIdentifier.contains("AppleExerciseTime") {
            let minutes = max(
                1,
                record.endDate.timeIntervalSince(record.startDate) / 60
            )
            return value / minutes
        }
        return value
    }

    private static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func isDirectGroundTruth(_ identifier: String) -> Bool {
        identifier == "HKWorkoutTypeIdentifier"
            || identifier == "HKWorkoutRouteTypeIdentifier"
            || identifier == "HKCategoryTypeIdentifierSleepAnalysis"
            || identifier == "HKCategoryTypeIdentifierMindfulSession"
    }

    private static func isHealthEvent(_ identifier: String) -> Bool {
        identifier.hasPrefix("HKClinicalTypeIdentifier")
            || identifier.hasPrefix("HKScoredAssessmentTypeIdentifier")
            || identifier.contains("StateOfMind")
            || identifier.contains("Handwashing")
            || identifier.contains("Toothbrushing")
            || identifier.contains("Pregnancy")
            || identifier.contains("Menstrual")
            || identifier.contains("Ovulation")
            || identifier.contains("Cervical")
            || identifier.contains("SexualActivity")
            || identifier.contains("Lactation")
            || identifier.contains("Contraceptive")
            || identifier.contains("Symptom")
            || HealthKitTypeCatalog.descriptor(for: identifier)?.group == "증상"
            || identifier.contains("HeartRateEvent")
            || identifier.contains("RhythmEvent")
            || identifier.contains("CardioFitnessEvent")
            || identifier.contains("HypertensionEvent")
            || identifier.contains("SleepApneaEvent")
    }

    private static func healthBehavior(_ identifier: String) -> String {
        if identifier.contains("Handwashing")
            || identifier.contains("Toothbrushing")
            || identifier.contains("StateOfMind") {
            return "wellness"
        }
        return "vitals"
    }

    private static func provenance(
        records: [HealthKitSampleRecord],
        rule: String
    ) -> [String] {
        let types = Set(records.map(\.typeIdentifier)).sorted()
        let sources = Set(records.compactMap(\.sourceName)).sorted()
        let ids = records.prefix(8).map { $0.uuid.uuidString }
        var evidence = [
            "HealthKit 원본 기반 자동판정",
            "rule=\(rule)",
            "types=\(types.joined(separator: ","))",
            "sampleUUIDs=\(ids.joined(separator: ","))",
            "ruleVersion=\(modelVersion)",
        ]
        if records.count > ids.count {
            evidence.append("sampleCount=\(records.count)")
        }
        if !sources.isEmpty {
            evidence.append("sources=\(sources.joined(separator: ","))")
        }
        return evidence
    }

    private static func stableUUID(_ seed: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff)
            bytes[index + 8] = UInt8(
                (second >> UInt64(index * 8)) & 0xff
            )
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
