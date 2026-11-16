import Foundation
import CryptoKit
import TaptionPlanEngine

/// Builds a display-only route from archived and live sensor readings.  It
/// never writes to either input collection or changes an `ActualRecord`.
enum RouteTimelineDataEngine {
    static let maximumInterpolationGap: TimeInterval = 15 * 60
    static let maximumDisplayReadingCount = 4_096
    static let maximumApproximateDisplayAccuracy: Double = 1_000

    struct ActualIndex {
        fileprivate let dayStart: Date
        fileprivate let dayEnd: Date
        fileprivate let dayActuals: [ActualRecord]
        fileprivate let automatic: [ActualRecord]
        fileprivate let categories: CategoryIndex

        fileprivate init(
            selectedDate: Date,
            actuals: [ActualRecord],
            calendar: Calendar
        ) {
            let resolvedDayStart = calendar.startOfDay(for: selectedDate)
            let resolvedDayEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: resolvedDayStart
            ) ?? resolvedDayStart.addingTimeInterval(24 * 60 * 60)
            let resolvedDayActuals = actuals.filter { actual in
                actual.startedAt < resolvedDayEnd
                    && (actual.endedAt.map { $0 > resolvedDayStart } ?? true)
            }
            let daySpan = TimeSpan(
                start: resolvedDayStart,
                end: resolvedDayEnd
            )
            let resolvedAutomatic = RouteTimelineDataEngine.automaticRecords(
                resolvedDayActuals,
                intersecting: daySpan,
                through: resolvedDayEnd
            )
            let resolvedCategories = CategoryIndex(
                actuals: resolvedAutomatic,
                dayStart: resolvedDayStart,
                cutoff: resolvedDayEnd
            )
            dayStart = resolvedDayStart
            dayEnd = resolvedDayEnd
            dayActuals = resolvedDayActuals
            automatic = resolvedAutomatic
            categories = resolvedCategories
        }
    }

    static func actualIndex(
        selectedDate: Date,
        actuals: [ActualRecord],
        calendar: Calendar = .autoupdatingCurrent
    ) -> ActualIndex {
        ActualIndex(
            selectedDate: selectedDate,
            actuals: actuals,
            calendar: calendar
        )
    }

    struct DisplayMeterPoint {
        var east: Double
        var north: Double
    }

    static func project(
        selectedDate: Date,
        through timelineDate: Date? = nil,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        actualIndex cachedActualIndex: ActualIndex? = nil,
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let requestedCutoff = timelineDate ?? dayEnd
        let cutoff = min(dayEnd, max(dayStart, requestedCutoff))
        let daySpan = TimeSpan(start: dayStart, end: dayEnd)
        let actualIndex: ActualIndex
        if let cachedActualIndex,
           cachedActualIndex.dayStart == dayStart,
           cachedActualIndex.dayEnd == dayEnd {
            actualIndex = cachedActualIndex
        } else {
            actualIndex = ActualIndex(
                selectedDate: selectedDate,
                actuals: actuals,
                calendar: calendar
            )
        }
        let dayActuals = actualIndex.dayActuals.filter {
            $0.startedAt <= cutoff
        }
        let automatic = automaticRecords(
            actualIndex.automatic,
            intersecting: daySpan,
            through: cutoff
        )
        let categoryIndex = actualIndex.categories
        let confirmedSubwayIndex = RouteConfirmedSubwayIntervalIndex(
            travel: travel
        )
        let combinedReadings = readings + liveReadings
        let allDayReadings = (readingsAreNormalized
            ? combinedReadings
            : normalizedReadings(combinedReadings)).filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
                && $0.timestamp >= dayStart && $0.timestamp < dayEnd
        }
        let coordinateIndex = CoordinateIndex(
            readings: allDayReadings,
            includesApproximateLocations: readingsAreNormalized,
            filtersSparseConnections: filtersSparseRouteConnections
        )
        let sleepSpans = MapHomeSleepLocationPolicy.spans(
            actuals: dayActuals,
            confirmedSleepSpans: confirmedSleepSpans,
            sleepSessions: sleepSessions,
            in: daySpan,
            through: cutoff
        )
        let sleepAnchors = MapHomeSleepLocationPolicy.anchors(
            for: sleepSpans,
            readings: allDayReadings
        )
        let visibleReadings = allDayReadings.filter {
            $0.timestamp <= cutoff
        }
        let samples = visibleReadings.compactMap { reading -> RouteTimelineSample? in
            guard let point = validPoint(
                from: reading,
                includesApproximateLocations: readingsAreNormalized
            ) else { return nil }
            return RouteTimelineSample(
                id: reading.id,
                timestamp: reading.timestamp,
                point: point,
                category: categoryIndex.category(at: reading.timestamp)
            )
        }
        let selectedCategory = timelineDate.map { _ in
            categoryIndex.category(at: cutoff)
        }
        let coordinateAtCutoff: GeoPoint?
        if let sleepAnchor = MapHomeSleepLocationPolicy.contains(
            cutoff,
            in: sleepAnchors
        )?.point {
            coordinateAtCutoff = sleepAnchor
        } else {
            coordinateAtCutoff = confirmedSubwayCoordinate(
                at: cutoff,
                index: confirmedSubwayIndex
            ) ?? coordinateIndex.playbackCoordinate(
                at: cutoff,
                sleepAnchors: sleepAnchors
            )?.point
        }
        let segments = makeSegments(
            samples: samples,
            coordinateIndex: coordinateIndex,
            actuals: automatic,
            categoryIndex: categoryIndex,
            confirmedSubwayIndex: confirmedSubwayIndex,
            cutoff: cutoff,
            selectedCategory: selectedCategory,
            selectedSpan: selectedSpan,
            sleepSpans: sleepSpans,
            sleepAnchors: sleepAnchors
        )
        return RouteTimelineProjection(
            selectedDate: selectedDate,
            cutoff: cutoff,
            selectedCategory: selectedCategory,
            samples: samples,
            segments: segments,
            coordinateAtCutoff: coordinateAtCutoff
        )
    }

    static func project(
        selectedDate: Date,
        throughMinute minute: Int?,
        selectedSpan: TimeSpan? = nil,
        actuals: [ActualRecord],
        actualIndex: ActualIndex? = nil,
        travel: [TravelSegment] = [],
        readings: [SensorReading],
        liveReadings: [SensorReading] = [],
        readingsAreNormalized: Bool = false,
        filtersSparseRouteConnections: Bool = false,
        confirmedSleepSpans: [TimeSpan] = [],
        sleepSessions: [SleepSession] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RouteTimelineProjection {
        let cutoff = minute.map {
            timelineDate(
                selectedDate: selectedDate,
                minute: $0,
                calendar: calendar
            )
        }
        return project(
            selectedDate: selectedDate,
            through: cutoff,
            selectedSpan: selectedSpan,
            actuals: actuals,
            actualIndex: actualIndex,
            travel: travel,
            readings: readings,
            liveReadings: liveReadings,
            readingsAreNormalized: readingsAreNormalized,
            filtersSparseRouteConnections: filtersSparseRouteConnections,
            confirmedSleepSpans: confirmedSleepSpans,
            sleepSessions: sleepSessions,
            calendar: calendar
        )
    }

    static func timelineDate(
        selectedDate: Date,
        minute: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let dayStart = calendar.startOfDay(for: selectedDate)
        let clampedMinute = min(1_440, max(0, minute))
        if clampedMinute == 1_440 {
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(24 * 60 * 60)
        }
        return calendar.date(
            byAdding: .minute,
            value: clampedMinute,
            to: dayStart
        ) ?? dayStart
    }

    static func normalizedReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        normalizedReadings(
            readings,
            includesApproximateLocations: false,
            cancellationCheck: {}
        )
    }

    static func normalizedReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try normalizedReadings(
            readings,
            includesApproximateLocations: false,
            cancellationCheck: cancellationCheck
        )
    }

    static func normalizedDisplayReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        normalizedReadings(
            readings,
            includesApproximateLocations: true,
            cancellationCheck: {}
        )
    }

    static func normalizedDisplayReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try normalizedReadings(
            readings,
            includesApproximateLocations: true,
            cancellationCheck: cancellationCheck
        )
    }

    private static func normalizedReadings(
        _ readings: [SensorReading],
        includesApproximateLocations: Bool,
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        var preferredByTimestamp: [Date: SensorReading] = [:]
        preferredByTimestamp.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard RouteTimelineTimestamp.isValid(reading.timestamp),
                  validPoint(
                    from: reading,
                    includesApproximateLocations: includesApproximateLocations
                  ) != nil else { continue }
            if let current = preferredByTimestamp[reading.timestamp] {
                let selected = preferredReading(reading, current)
                    ? reading
                    : current
                if reading.trackingSessionEnded == true
                    || current.trackingSessionEnded == true {
                    var merged = selected
                    merged.trackingSessionEnded = true
                    preferredByTimestamp[reading.timestamp] = merged
                } else {
                    preferredByTimestamp[reading.timestamp] = selected
                }
            } else {
                preferredByTimestamp[reading.timestamp] = reading
            }
        }
        var preferred: [SensorReading] = []
        preferred.reserveCapacity(preferredByTimestamp.count)
        for (index, reading) in preferredByTimestamp.values.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            preferred.append(reading)
        }
        return try droppingBracketedApproximates(RouteTimelineCancellableSort.sorted(
            preferred,
            by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        ), when: includesApproximateLocations)
    }

    static func playbackCoordinate(
        at date: Date,
        inNormalizedReadings readings: [SensorReading],
        sleepAnchors: [MapHomeSleepLocationAnchor] = []
    ) -> GeoPoint? {
        guard let first = readings.first,
              validPoint(
                from: first,
                includesApproximateLocations: true
              ) != nil else { return nil }
        if let sleepAnchor = MapHomeSleepLocationPolicy.contains(
            date,
            in: sleepAnchors
        )?.point {
            return sleepAnchor
        }

        // A route archive can begin after the selected timeline time (for
        // example, when only the recent live window has been loaded). Keep
        // the earliest archived/location anchor visible instead of removing
        // the historical marker until a newer sample is available.
        if date < first.timestamp {
            return validPoint(
                from: first,
                includesApproximateLocations: true
            )
        }

        var lower = 0
        var upper = readings.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let beforeIndex = lower - 1
        let before = readings[beforeIndex]
        guard let beforePoint = validPoint(
            from: before,
            includesApproximateLocations: true
        ) else { return nil }
        guard before.timestamp < date else { return beforePoint }
        guard lower < readings.count,
              let afterPoint = validPoint(
                from: readings[lower],
                includesApproximateLocations: true
              ) else {
            return beforePoint
        }
        let gap = readings[lower].timestamp.timeIntervalSince(before.timestamp)
        guard gap > 0, gap <= maximumInterpolationGap else {
            return beforePoint
        }
        return interpolate(
            beforePoint,
            afterPoint,
            ratio: date.timeIntervalSince(before.timestamp) / gap
        )
    }

    static func displayReadings(
        from normalizedReadings: [SensorReading],
        maximumCount: Int = maximumDisplayReadingCount
    ) -> [SensorReading] {
        displayReadings(
            from: normalizedReadings,
            maximumCount: maximumCount,
            cancellationCheck: {}
        )
    }

    static func displayReadings(
        from normalizedReadings: [SensorReading],
        maximumCount: Int = maximumDisplayReadingCount,
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        let maximumCount = max(2, maximumCount)
        guard normalizedReadings.count > maximumCount else {
            return normalizedReadings
        }

        let reduced = try reducedDisplayIndices(
            normalizedReadings,
            maximumCount: maximumCount,
            cancellationCheck: cancellationCheck
        )
        let indices: [Int]
        if reduced.count > maximumCount {
            indices = try evenlySampledIndices(
                reduced,
                count: maximumCount,
                cancellationCheck: cancellationCheck
            )
        } else {
            var selected = Set<Int>()
            selected.reserveCapacity(reduced.count)
            for (offset, index) in reduced.enumerated() {
                if offset.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(index)
            }
            let lastIndex = normalizedReadings.count - 1
            let scale = Double(lastIndex) / Double(maximumCount - 1)
            for outputIndex in 0..<maximumCount where selected.count < maximumCount {
                if outputIndex.isMultiple(of: 256) { try cancellationCheck() }
                selected.insert(
                    min(
                        lastIndex,
                        Int((Double(outputIndex) * scale).rounded())
                    )
                )
            }
            if selected.count < maximumCount {
                for (offset, index) in normalizedReadings.indices.enumerated() {
                    if offset.isMultiple(of: 256) { try cancellationCheck() }
                    guard selected.count < maximumCount else { break }
                    selected.insert(index)
                }
            }
            indices = try RouteTimelineCancellableSort.sorted(
                try RouteTimelineCancellableSort.collect(
                    selected,
                    cancellationCheck: cancellationCheck
                ),
                by: <,
                cancellationCheck: cancellationCheck
            )
        }
        var result: [SensorReading] = []
        result.reserveCapacity(indices.count)
        for (offset, index) in indices.enumerated() {
            if offset.isMultiple(of: 256) { try cancellationCheck() }
            result.append(normalizedReadings[index])
        }
        return result
    }

    private static func automaticRecords(
        _ actuals: [ActualRecord],
        intersecting day: TimeSpan,
        through cutoff: Date
    ) -> [ActualRecord] {
        actuals.filter { actual in
            guard AutomaticRecordTimelineEngine.isImmutable(actual) else {
                return false
            }
            let overlapsVisibleInterval = actual.startedAt < cutoff
                && (actual.endedAt ?? cutoff) > day.start
                && actual.startedAt < day.end
            let activeAtCutoff = cutoff >= day.start
                && cutoff < day.end
                && actual.startedAt <= cutoff
                && actual.endedAt.map { cutoff < $0 } != false
            return overlapsVisibleInterval || activeAtCutoff
        }
    }

    struct CategoryIndex {
        private let boundaries: [Date]
        private let categories: [RouteTimelineCategory]

        init(actuals: [ActualRecord], dayStart: Date, cutoff: Date) {
            let starts = actuals.indices.sorted {
                let left = actuals[$0]
                let right = actuals[$1]
                if left.startedAt != right.startedAt {
                    return left.startedAt < right.startedAt
                }
                return left.id.uuidString < right.id.uuidString
            }
            var points = [dayStart, cutoff]
            for actual in actuals where actual.startedAt <= cutoff {
                points.append(max(dayStart, actual.startedAt))
                points.append(max(
                    dayStart,
                    min(cutoff, actual.endedAt ?? cutoff)
                ))
            }
            boundaries = Array(Set(points)).sorted()

            var heap: [Int] = []
            var nextStart = 0
            var builtCategories: [RouteTimelineCategory] = []
            for date in boundaries {
                while nextStart < starts.count,
                      actuals[starts[nextStart]].startedAt <= date {
                    Self.push(starts[nextStart], into: &heap, actuals: actuals)
                    nextStart += 1
                }
                while let winner = heap.first,
                      actuals[winner].endedAt.map({ $0 <= date }) == true {
                    _ = Self.pop(from: &heap, actuals: actuals)
                }
                if let winner = heap.first {
                    builtCategories.append(.resolve(
                        RecordAnalysisCategoryPolicy.categoryID(
                            for: actuals[winner]
                        )
                    ))
                } else {
                    builtCategories.append(.unconfirmed)
                }
            }
            categories = builtCategories
        }

        func category(at date: Date) -> RouteTimelineCategory {
            var lower = 0
            var upper = boundaries.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if boundaries[middle] <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower == 0 ? .unconfirmed : categories[lower - 1]
        }

        private static func push(
            _ index: Int,
            into heap: inout [Int],
            actuals: [ActualRecord]
        ) {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard RouteTimelineDataEngine.lowerPriority(
                    actuals[heap[parent]],
                    than: actuals[heap[child]]
                ) else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        private static func pop(
            from heap: inout [Int],
            actuals: [ActualRecord]
        ) -> Int? {
            guard let first = heap.first else { return nil }
            let last = heap.removeLast()
            guard !heap.isEmpty else { return first }
            heap[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                var highest = left
                if right < heap.count,
                   RouteTimelineDataEngine.lowerPriority(
                       actuals[heap[left]],
                       than: actuals[heap[right]]
                   ) {
                    highest = right
                }
                guard RouteTimelineDataEngine.lowerPriority(
                    actuals[heap[parent]],
                    than: actuals[heap[highest]]
                ) else { break }
                heap.swapAt(parent, highest)
                parent = highest
            }
            return first
        }
    }

    private static func lowerPriority(
        _ lhs: ActualRecord,
        than rhs: ActualRecord
    ) -> Bool {
        let leftCategory = RecordAnalysisCategoryPolicy.categoryID(for: lhs)
        let rightCategory = RecordAnalysisCategoryPolicy.categoryID(for: rhs)
        let leftPhase = DayPhase.phase(forActivityCategory: leftCategory).precedence
        let rightPhase = DayPhase.phase(forActivityCategory: rightCategory).precedence
        if leftPhase != rightPhase { return leftPhase < rightPhase }
        if lhs.manuallyCorrected != rhs.manuallyCorrected {
            return !lhs.manuallyCorrected
        }
        let leftConfidence = confidenceRank(lhs.confidence)
        let rightConfidence = confidenceRank(rhs.confidence)
        if leftConfidence != rightConfidence { return leftConfidence < rightConfidence }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func confidenceRank(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}
