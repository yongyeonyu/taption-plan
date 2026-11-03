import Foundation
import TaptionPlanEngine

struct TimeSpanValueIndex<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let span: TimeSpan
        let inputOrder: Int
    }

    private let entries: [Entry]
    private let prefixMaximumEnds: [Date]

    init(_ values: [Value], span: (Value) -> TimeSpan) {
        entries = values.enumerated().compactMap { inputOrder, value in
            let valueSpan = span(value)
            guard valueSpan.duration > 0,
                  RouteTimelineTimestamp.isValid(valueSpan.start),
                  RouteTimelineTimestamp.isValid(valueSpan.end) else {
                return nil
            }
            return Entry(
                value: value,
                span: valueSpan,
                inputOrder: inputOrder
            )
        }.sorted { lhs, rhs in
            if lhs.span.start != rhs.span.start {
                return lhs.span.start < rhs.span.start
            }
            return lhs.inputOrder < rhs.inputOrder
        }

        var latestEnd = Date.distantPast
        prefixMaximumEnds = entries.map { entry in
            latestEnd = max(latestEnd, entry.span.end)
            return latestEnd
        }
    }

    func values(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?
    ) -> [Value] {
        let range = candidateRange(
            overlapping: span,
            inspectionCount: &inspectionCount
        )
        var matches = entries[range].filter { entry in
            inspectionCount? += 1
            return entry.span.intersection(with: span) != nil
        }
        matches.sort { $0.inputOrder < $1.inputOrder }
        return matches.map(\.value)
    }

    func contains(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?,
        where predicate: (Value, TimeSpan) -> Bool
    ) -> Bool {
        let range = candidateRange(
            overlapping: span,
            inspectionCount: &inspectionCount
        )
        for entry in entries[range] {
            inspectionCount? += 1
            guard let overlap = entry.span.intersection(with: span) else {
                continue
            }
            if predicate(entry.value, overlap) { return true }
        }
        return false
    }

    private func candidateRange(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?
    ) -> Range<Int> {
        guard span.duration > 0,
              RouteTimelineTimestamp.isValid(span.start),
              RouteTimelineTimestamp.isValid(span.end),
              !entries.isEmpty else { return 0..<0 }

        var lower = 0
        var upper = prefixMaximumEnds.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if prefixMaximumEnds[middle] > span.start {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let first = lower

        upper = entries.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if entries[middle].span.start < span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return first..<lower
    }
}

struct SensorEvidenceTimeIndex: Sendable {
    private struct ReadingEntry: Sendable {
        let reading: SensorReading
        let inputOrder: Int
    }

    private struct HealthEntry: Sendable {
        let evidence: AppleMovementEvidence
        let inputOrder: Int
    }

    private let readings: [ReadingEntry]
    private let healthEntries: [HealthEntry]
    private let healthPrefixMaximumEnds: [Date]

    init(
        readings: [SensorReading],
        healthEvidence: [AppleMovementEvidence] = []
    ) {
        self.readings = readings.enumerated().compactMap { inputOrder, reading in
            guard RouteTimelineTimestamp.isValid(reading.timestamp) else {
                return nil
            }
            return ReadingEntry(reading: reading, inputOrder: inputOrder)
        }.sorted {
            if $0.reading.timestamp != $1.reading.timestamp {
                return $0.reading.timestamp < $1.reading.timestamp
            }
            return $0.inputOrder < $1.inputOrder
        }

        healthEntries = healthEvidence.enumerated().compactMap {
            inputOrder, evidence in
            guard RouteTimelineTimestamp.isValid(evidence.span.start),
                  RouteTimelineTimestamp.isValid(evidence.span.end),
                  evidence.span.duration > 0 else {
                return nil
            }
            return HealthEntry(evidence: evidence, inputOrder: inputOrder)
        }.sorted {
            if $0.evidence.span.start != $1.evidence.span.start {
                return $0.evidence.span.start < $1.evidence.span.start
            }
            return $0.inputOrder < $1.inputOrder
        }

        var latestEnd = Date.distantPast
        healthPrefixMaximumEnds = healthEntries.map { entry in
            latestEnd = max(latestEnd, entry.evidence.span.end)
            return latestEnd
        }
    }

    func readings(in span: TimeSpan) -> [SensorReading] {
        var inspectionCount: Int? = nil
        return readings(in: span, inspectionCount: &inspectionCount)
    }

    func readings(
        in span: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [SensorReading] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = readings(
            in: span,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    func readings(
        in span: TimeSpan,
        inspectionCount: inout Int?
    ) -> [SensorReading] {
        var lower = 0
        var upper = readings.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].reading.timestamp < span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = lower

        upper = readings.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].reading.timestamp <= span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var matches = Array(readings[first..<lower])
        inspectionCount? += matches.count
        matches.sort { $0.inputOrder < $1.inputOrder }
        return matches.map(\.reading)
    }

    func healthEvidence(
        overlapping span: TimeSpan
    ) -> [AppleMovementEvidence] {
        var inspectionCount: Int? = nil
        return healthEvidence(
            overlapping: span,
            inspectionCount: &inspectionCount
        )
    }

    func healthEvidence(
        overlapping span: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [AppleMovementEvidence] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = healthEvidence(
            overlapping: span,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    func healthEvidence(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?
    ) -> [AppleMovementEvidence] {
        guard span.duration > 0, !healthEntries.isEmpty else { return [] }

        var lower = 0
        var upper = healthPrefixMaximumEnds.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if healthPrefixMaximumEnds[middle] > span.start {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let first = lower

        upper = healthEntries.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if healthEntries[middle].evidence.span.start < span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var matches = healthEntries[first..<lower].filter { entry in
            inspectionCount? += 1
            return entry.evidence.span.intersection(with: span) != nil
        }
        matches.sort { $0.inputOrder < $1.inputOrder }
        return matches.map(\.evidence)
    }
}
