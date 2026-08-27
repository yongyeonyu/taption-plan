import Foundation

struct SleepAnalysisEngine: Sendable {
    var maximumGapBetweenSegments: TimeInterval = 90 * 60

    /// HealthKit's overnight sleep for a calendar day starts the evening
    /// before and ends at noon of that day.  Keeping the boundary in one
    /// place makes the query deterministic across midnight and time zones.
    static func overnightSpan(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let dayStart = calendar.startOfDay(for: date)
        let start = calendar.date(
            byAdding: .hour,
            value: -6,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-6 * 3_600)
        let end = calendar.date(
            byAdding: .hour,
            value: 12,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(12 * 3_600)
        return TimeSpan(start: start, end: end)
    }

    func sessions(
        from segments: [SleepSegment],
        inside requestedSpan: TimeSpan? = nil
    ) -> [SleepSession] {
        let clipped = deduplicatedSegments(segments).compactMap { segment -> SleepSegment? in
            guard let requestedSpan else { return segment }
            guard let overlap = segment.span.intersection(with: requestedSpan) else {
                return nil
            }
            var value = segment
            value.span = overlap
            return value
        }
        let ordered = clipped.sorted {
            if $0.span.start == $1.span.start {
                return $0.span.end < $1.span.end
            }
            return $0.span.start < $1.span.start
        }
        guard let first = ordered.first else { return [] }

        var groups: [[SleepSegment]] = []
        var current = [first]
        var currentEnd = first.span.end

        for segment in ordered.dropFirst() {
            if segment.span.start.timeIntervalSince(currentEnd) > maximumGapBetweenSegments {
                groups.append(current)
                current = [segment]
                currentEnd = segment.span.end
            } else {
                current.append(segment)
                currentEnd = max(currentEnd, segment.span.end)
            }
        }
        groups.append(current)

        return groups.compactMap(makeSession)
    }

    private func makeSession(_ segments: [SleepSegment]) -> SleepSession? {
        let asleepSegments = segments.filter(\.stage.isAsleep)
        // iPhone and third-party HealthKit sources may provide only an
        // `inBed` sample. Preserve that source record instead of requiring an
        // Apple Watch sleep stage.
        let sessionSegments = asleepSegments.isEmpty
            ? segments.filter { $0.stage == .inBed }
            : asleepSegments
        guard let first = sessionSegments.min(by: { $0.span.start < $1.span.start }) else {
            return nil
        }
        let last = sessionSegments.max(by: { $0.span.end < $1.span.end }) ?? first
        let inBedDuration = unionDuration(
            segments.filter { $0.stage == .inBed }.map(\.span)
        )
        let asleepDuration: TimeInterval
        let stageDurations = resolvedStageDurations(segments)
        asleepDuration = stageDurations.reduce(0) {
            $0 + ($1.key.isAsleep ? $1.value : 0)
        }
        guard asleepDuration > 0 || inBedDuration > 0 else { return nil }

        let sessionEnd: Date
        if asleepSegments.isEmpty {
            sessionEnd = segments
                .filter { $0.stage == .inBed }
                .map(\.span.end)
                .max() ?? last.span.end
        } else {
            sessionEnd = segments
                .filter { $0.stage == .awake && $0.span.end > last.span.end }
                .map(\.span.end)
                .max() ?? last.span.end
        }

        return SleepSession(
            id: first.id,
            span: TimeSpan(start: first.span.start, end: sessionEnd),
            asleepDuration: asleepDuration,
            awakeDuration: stageDurations[.awake, default: 0],
            inBedDuration: inBedDuration,
            stageDurations: stageDurations,
            sourceNames: unique(
                segments.map(\.sourceName).filter { !$0.isEmpty }
            ),
            segments: segments.sorted { $0.span.start < $1.span.start }
        )
    }

    private func resolvedStageDurations(
        _ segments: [SleepSegment]
    ) -> [SleepStage: TimeInterval] {
        let boundaries = Array(
            Set(segments.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [:] }

        var durations: [SleepStage: TimeInterval] = [:]
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let active = segments.filter {
                $0.span.start < end && start < $0.span.end
            }
            guard let selected = active.max(by: {
                stagePriority($0.stage) < stagePriority($1.stage)
            }) else {
                continue
            }
            durations[selected.stage, default: 0] += end.timeIntervalSince(start)
        }
        return durations
    }

    private func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var duration: TimeInterval = 0

        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                duration += current.duration
                current = span
            }
        }
        return duration + current.duration
    }

    private func deduplicatedSegments(
        _ segments: [SleepSegment]
    ) -> [SleepSegment] {
        var seen = Set<UUID>()
        return segments.filter { seen.insert($0.id).inserted }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func stagePriority(_ stage: SleepStage) -> Int {
        stage.overlapPriority
    }
}
