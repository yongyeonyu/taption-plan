import CoreMotion
import Foundation
@preconcurrency import ActivityKit
import CoreLocation
import Observation
import OSLog
import UIKit
import WidgetKit
import TaptionPlanCore


private struct WatchSensorTimelineData: Sendable {
    let summaries: [TaptionWatchSensorSummary]
    let accelerationChunks: [TaptionWatchAccelerationChunk]

    var accelerationSamples: [TaptionWatchAccelerationSample] {
        let samples = accelerationChunks.flatMap(\.samples)
        return Dictionary(
            samples.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.sequence < $1.sequence
            }
            return $0.capturedAt < $1.capturedAt
        }
    }
}

enum ActivityClassificationRecordOrdering {
    static func sorted(
        _ records: [ActualRecord],
        cancellationCheck: () throws -> Void
    ) throws -> [ActualRecord] {
        try RouteTimelineCancellableSort.sorted(
            records,
            by: {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }
}

private struct WatchSummaryVersion: Codable, Comparable, Sendable {
    let sequence: Int
    let revision: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence
            ? lhs.revision < rhs.revision
            : lhs.sequence < rhs.sequence
    }
}

struct ActivityClassificationSourceSnapshot: Sendable {
    let revision: UInt64
    let actuals: [ActualRecord]
    let travel: [TravelSegment]
    let corrections: [UUID: ActivityCorrection]
    let suppressedIDs: Set<UUID>

    init(revision: UInt64, snapshot: TaptionDataSnapshot) {
        self.revision = revision
        actuals = snapshot.actuals
        travel = snapshot.travel
        corrections = snapshot.settings.activityCorrections
        suppressedIDs = snapshot.settings.suppressedActualIDs
    }
}

final class ActivityClassificationRevisionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ revision: UInt64 = 0) {
        value = revision
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to revision: UInt64) {
        lock.lock()
        value = revision
        lock.unlock()
    }

    func check(_ expectedRevision: UInt64) throws {
        guard currentRevision == expectedRevision else { throw CancellationError() }
    }
}

@MainActor
enum ActivityClassificationRetry {
    static func apply<Result: Sendable>(
        capture: @MainActor () -> ActivityClassificationSourceSnapshot,
        currentRevision: @MainActor () -> UInt64,
        classify: @MainActor (ActivityClassificationSourceSnapshot) async -> Result?,
        commit: @MainActor (ActivityClassificationSourceSnapshot, Result) -> Void
    ) async -> Bool {
        for _ in 0..<2 {
            guard !Task.isCancelled else { return false }
            let source = capture()
            let result = await classify(source)
            guard !Task.isCancelled else { return false }
            guard source.revision == currentRevision() else { continue }
            guard let result else { return false }
            commit(source, result)
            return true
        }
        return false
    }
}

/// The WBS store loads one normalized immutable workspace and derives the
/// visible presentation from that snapshot. Plan follows the same boundary
/// for a map day: persisted iPhone/Watch data is read once, then day-scoped
/// arrays are derived without changing the source snapshot or raw readings.

enum MapCurrentLocationAnchorPolicy {
    static let maximumAge: TimeInterval = 5 * 60
    static let maximumPreciseAccuracy =
        TrackingSessionPolicy.activeHorizontalAccuracyLimit

    static func latestValidReading(
        in readings: [SensorReading],
        now: Date = .now
    ) -> SensorReading? {
        let valid = readings.filter { isValid($0, now: now) }
        return valid
            .filter(isPrecise)
            .max { $0.timestamp < $1.timestamp }
            ?? valid
                .filter { $0.locationFixQuality == .approximate }
                .max { $0.timestamp < $1.timestamp }
    }

    private static func isValid(
        _ reading: SensorReading,
        now: Date
    ) -> Bool {
        guard let point = reading.point,
              reading.timestamp <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(reading.timestamp) <= maximumAge else {
            return false
        }
        return (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy >= 0
            && (isPrecise(reading) || reading.locationFixQuality == .approximate)
    }

    private static func isPrecise(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable || reading.locationFixQuality == .precise,
              let point = reading.point else { return false }
        return point.horizontalAccuracy <= maximumPreciseAccuracy
    }
}

enum BackgroundLocationCollectionPolicy {
    static func isEnabled(hasAlwaysAuthorization: Bool) -> Bool {
        hasAlwaysAuthorization
    }
}

enum WatchHealthSnapshotRetryPolicy {
    static let minimumRetryInterval: TimeInterval = 60

    static func accepts(
        capturedAt: Date,
        fingerprint: String?,
        receivedAt: Date,
        lastAppliedAt: Date?,
        rawRetryAt: Date?,
        rawRetryFingerprint: String?,
        lastRawRetryAttemptAt: Date?
    ) -> Bool {
        guard let lastAppliedAt else { return true }
        if capturedAt > lastAppliedAt { return true }
        guard capturedAt == lastAppliedAt,
              capturedAt == rawRetryAt,
              let fingerprint,
              fingerprint == rawRetryFingerprint else {
            return false
        }
        return lastRawRetryAttemptAt.map {
            receivedAt.timeIntervalSince($0) >= minimumRetryInterval
        } ?? true
    }
}

enum ConfirmedSleepSpanEditor {
    static func replacing(
        _ existing: [TimeSpan],
        removing: [TimeSpan] = [],
        adding: [TimeSpan] = []
    ) -> [TimeSpan] {
        let cuts = normalized(removing)
        let remaining = normalized(existing).flatMap { span in
            cuts.reduce(into: [span]) { pieces, cut in
                pieces = pieces.flatMap { subtracting($0, by: cut) }
            }
        }
        return normalized(remaining + adding)
    }

    private static func subtracting(
        _ span: TimeSpan,
        by cut: TimeSpan
    ) -> [TimeSpan] {
        guard let overlap = span.intersection(with: cut) else {
            return [span]
        }
        var result: [TimeSpan] = []
        if span.start < overlap.start {
            result.append(TimeSpan(start: span.start, end: overlap.start))
        }
        if overlap.end < span.end {
            result.append(TimeSpan(start: overlap.end, end: span.end))
        }
        return result
    }

    private static func normalized(_ spans: [TimeSpan]) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var result: [TimeSpan] = []
        for span in ordered {
            guard let previous = result.last,
                  span.start <= previous.end else {
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
}

enum PlanBackupRouteFallbackEngine {
    static let maximumPlaceGap: TimeInterval = 2 * 60 * 60
    static let maximumRouteGap: TimeInterval = 15 * 60
    static let fallbackSampleInterval: TimeInterval = 10 * 60

    static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading] = []
    ) -> [SensorReading] {
        var inspectionCount: Int? = nil
        return readings(
            travel: travel,
            places: places,
            in: span,
            supplementing: archivedReadings,
            endpointInspectionCount: &inspectionCount
        )
    }

    static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading] = [],
        endpointInspectionCount: inout Int
    ) -> [SensorReading] {
        var inspectionCount: Int? = endpointInspectionCount
        let result = readings(
            travel: travel,
            places: places,
            in: span,
            supplementing: archivedReadings,
            endpointInspectionCount: &inspectionCount
        )
        endpointInspectionCount = inspectionCount ?? endpointInspectionCount
        return result
    }

    private static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading],
        endpointInspectionCount: inout Int?
    ) -> [SensorReading] {
        let placesByID = Dictionary(places.map {
            ($0.id, $0)
        }, uniquingKeysWith: { first, _ in first })
        let endpointIndex = RouteEndpointIndex(places: places)
        let routeCoverage = RouteCoverageIndex(readings: archivedReadings)
        let segments = travel
            .filter {
                guard let visibleSpan = $0.span.intersection(with: span) else {
                    return false
                }
                return routeCoverage.needsFallback(in: visibleSpan)
            }
            .sorted { $0.span.start < $1.span.start }
        var readings: [SensorReading] = []
        for segment in segments {
            let samples = routeSamples(
                for: segment,
                placesByID: placesByID,
                endpointIndex: endpointIndex,
                in: span,
                endpointInspectionCount: &endpointInspectionCount
            )
            readings.append(contentsOf: samples.map { sample in
                SensorReading(
                    timestamp: sample.date,
                    point: sample.point,
                    locationFixQuality: .precise,
                    motion: motion(for: segment.mode),
                    motionConfidence: segment.confidence,
                    gpsAvailable: true,
                    behavior: segment.mode.rawValue
                )
            })
        }
        return readings
    }

    private struct RouteEndpointIndex {
        private struct Entry {
            let inputOrder: Int
            let start: Date
            let end: Date
            let point: GeoPoint
        }

        private let orderedByEnd: [Entry]
        private let orderedByStart: [Entry]

        init(places: [PlaceStay]) {
            let entries = places.enumerated().compactMap { inputOrder, place in
                place.point.map {
                    Entry(
                        inputOrder: inputOrder,
                        start: place.span.start,
                        end: place.span.end,
                        point: $0
                    )
                }
            }
            orderedByEnd = entries.sorted {
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.inputOrder > $1.inputOrder
            }
            orderedByStart = entries.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.inputOrder < $1.inputOrder
            }
        }

        func previousPoint(
            before date: Date,
            inspectionCount: inout Int?
        ) -> GeoPoint? {
            var lower = 0
            var upper = orderedByEnd.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if orderedByEnd[middle].end <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return nil }
            let entry = orderedByEnd[lower - 1]
            guard date.timeIntervalSince(entry.end) <= maximumPlaceGap else {
                return nil
            }
            return entry.point
        }

        func nextPoint(
            after date: Date,
            inspectionCount: inout Int?
        ) -> GeoPoint? {
            var lower = 0
            var upper = orderedByStart.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if orderedByStart[middle].start < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower < orderedByStart.count else { return nil }
            let entry = orderedByStart[lower]
            guard entry.start.timeIntervalSince(date) <= maximumPlaceGap else {
                return nil
            }
            return entry.point
        }
    }

    private struct RouteCoverageIndex {
        private let timestamps: [Date]

        init(readings: [SensorReading]) {
            timestamps = readings.compactMap { reading -> Date? in
                guard reading.gpsAvailable,
                      RouteTimelineTimestamp.isValid(reading.timestamp),
                      let point = reading.point,
                      point.latitude.isFinite,
                      point.longitude.isFinite,
                      (-90...90).contains(point.latitude),
                      (-180...180).contains(point.longitude) else { return nil }
                return reading.timestamp
            }.sorted()
        }

        func needsFallback(in span: TimeSpan) -> Bool {
            let startIndex = lowerBound(for: span.start)
            let endIndex = upperBound(for: span.end)
            guard endIndex - startIndex >= 2 else { return true }
            let first = timestamps[startIndex]
            let last = timestamps[endIndex - 1]
            guard first.timeIntervalSince(span.start)
                    <= PlanBackupRouteFallbackEngine.maximumRouteGap,
                  span.end.timeIntervalSince(last)
                    <= PlanBackupRouteFallbackEngine.maximumRouteGap else {
                return true
            }
            guard startIndex + 1 < endIndex else { return false }
            for index in (startIndex + 1)..<endIndex
            where timestamps[index].timeIntervalSince(timestamps[index - 1])
                > PlanBackupRouteFallbackEngine.maximumRouteGap {
                return true
            }
            return false
        }

        private func lowerBound(for date: Date) -> Int {
            var lower = 0
            var upper = timestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if timestamps[middle] < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func upperBound(for date: Date) -> Int {
            var lower = 0
            var upper = timestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if timestamps[middle] <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }
    }

    private struct RouteSample {
        let date: Date
        let point: GeoPoint
    }

    private static func routeSamples(
        for segment: TravelSegment,
        placesByID: [UUID: PlaceStay],
        endpointIndex: RouteEndpointIndex,
        in requestedSpan: TimeSpan,
        endpointInspectionCount: inout Int?
    ) -> [RouteSample] {
        let coordinates = routeCoordinates(
            for: segment,
            placesByID: placesByID,
            endpointIndex: endpointIndex,
            endpointInspectionCount: &endpointInspectionCount
        )
        guard coordinates.count >= 2,
              segment.span.duration > 0,
              let visibleSpan = segment.span.intersection(with: requestedSpan)
        else { return [] }
        let startProgress = visibleSpan.start.timeIntervalSince(
            segment.span.start
        ) / segment.span.duration
        let endProgress = visibleSpan.end.timeIntervalSince(
            segment.span.start
        ) / segment.span.duration
        var progressValues = Set([startProgress, endProgress])
        if coordinates.count > 2 {
            for index in 1..<(coordinates.count - 1) {
                let progress = Double(index) / Double(coordinates.count - 1)
                guard progress > startProgress, progress < endProgress else {
                    continue
                }
                progressValues.insert(progress)
            }
        }
        var elapsed = (
            floor(
                visibleSpan.start.timeIntervalSince(segment.span.start)
                    / fallbackSampleInterval
            ) + 1
        ) * fallbackSampleInterval
        let visibleEndElapsed = visibleSpan.end.timeIntervalSince(segment.span.start)
        while elapsed < visibleEndElapsed {
            progressValues.insert(elapsed / segment.span.duration)
            elapsed += fallbackSampleInterval
        }
        return progressValues.sorted().map { progress in
            RouteSample(
                date: segment.span.start.addingTimeInterval(
                    segment.span.duration * progress
                ),
                point: coordinate(in: coordinates, progress: progress)
            )
        }
    }

    private static func coordinate(
        in coordinates: [GeoPoint],
        progress: Double
    ) -> GeoPoint {
        let clamped = min(max(progress, 0), 1)
        let position = clamped * Double(coordinates.count - 1)
        let lowerIndex = min(Int(position.rounded(.down)), coordinates.count - 1)
        let upperIndex = min(lowerIndex + 1, coordinates.count - 1)
        let fraction = position - Double(lowerIndex)
        let lower = coordinates[lowerIndex]
        let upper = coordinates[upperIndex]
        return GeoPoint(
            latitude: lower.latitude
                + (upper.latitude - lower.latitude) * fraction,
            longitude: RouteTimelineLongitude.interpolate(
                from: lower.longitude,
                to: upper.longitude,
                fraction: fraction
            ),
            altitude: lower.altitude
                + (upper.altitude - lower.altitude) * fraction,
            horizontalAccuracy: max(
                lower.horizontalAccuracy,
                upper.horizontalAccuracy
            ),
            verticalAccuracy: max(
                lower.verticalAccuracy,
                upper.verticalAccuracy
            )
        )
    }

    private static func routeCoordinates(
        for segment: TravelSegment,
        placesByID: [UUID: PlaceStay],
        endpointIndex: RouteEndpointIndex,
        endpointInspectionCount: inout Int?
    ) -> [GeoPoint] {
        if let subway = segment.subwayRoute?.coordinates,
           subway.count >= 2 {
            return subway
        }
        let from: GeoPoint?
        if let fromPlaceID = segment.fromPlaceID {
            from = placesByID[fromPlaceID]?.point
        } else {
            from = endpointIndex.previousPoint(
                before: segment.span.start,
                inspectionCount: &endpointInspectionCount
            )
        }
        let to: GeoPoint?
        if let toPlaceID = segment.toPlaceID {
            to = placesByID[toPlaceID]?.point
        } else {
            to = endpointIndex.nextPoint(
                after: segment.span.end,
                inspectionCount: &endpointInspectionCount
            )
        }
        return [from, to].compactMap { $0 }
    }

    private static func motion(for mode: TravelMode) -> MotionKind {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .bus, .subway, .taxi, .car, .train, .airplane, .ship:
            .automotive
        }
    }
}

private struct AppModelHistoryChange<Value: Hashable> {
    let id: UUID
    let before: Value?
    let after: Value?
}

private struct AppModelHistoryEntry {
    let plans: [AppModelHistoryChange<PlanRecord>]
    let manualActuals: [AppModelHistoryChange<ActualRecord>]
    let corrections: [AppModelHistoryChange<ActivityCorrection>]
    let addedLabels: Set<String>
    let removedLabels: Set<String>
    let addedSleepSpans: Set<TimeSpan>
    let removedSleepSpans: Set<TimeSpan>
    let addedSuppressedIDs: Set<UUID>
    let removedSuppressedIDs: Set<UUID>

    var isEmpty: Bool {
        plans.isEmpty && manualActuals.isEmpty && corrections.isEmpty
            && addedLabels.isEmpty && removedLabels.isEmpty
            && addedSleepSpans.isEmpty && removedSleepSpans.isEmpty
            && addedSuppressedIDs.isEmpty && removedSuppressedIDs.isEmpty
    }

    static func difference(
        from before: TaptionDataSnapshot,
        to after: TaptionDataSnapshot
    ) -> Self {
        let planOrigins: (PlanRecord) -> Bool = {
            $0.origin == .user || $0.origin == .repeatRule
        }
        let manualRecords: (ActualRecord) -> Bool = { $0.source == .manual }
        let oldLabels = Set(before.settings.customActivityLabels)
        let newLabels = Set(after.settings.customActivityLabels)
        let oldSleepSpans = Set(before.settings.confirmedSleepSpans)
        let newSleepSpans = Set(after.settings.confirmedSleepSpans)

        return Self(
            plans: changes(
                from: before.plans,
                to: after.plans,
                id: \.id,
                include: planOrigins
            ),
            manualActuals: changes(
                from: before.actuals,
                to: after.actuals,
                id: \.id,
                include: manualRecords
            ),
            corrections: dictionaryChanges(
                from: before.settings.activityCorrections,
                to: after.settings.activityCorrections
            ),
            addedLabels: newLabels.subtracting(oldLabels),
            removedLabels: oldLabels.subtracting(newLabels),
            addedSleepSpans: newSleepSpans.subtracting(oldSleepSpans),
            removedSleepSpans: oldSleepSpans.subtracting(newSleepSpans),
            addedSuppressedIDs: after.settings.suppressedActualIDs
                .subtracting(before.settings.suppressedActualIDs),
            removedSuppressedIDs: before.settings.suppressedActualIDs
                .subtracting(after.settings.suppressedActualIDs)
        )
    }

    func applying(
        to source: TaptionDataSnapshot,
        undo: Bool
    ) -> TaptionDataSnapshot? {
        var result = source
        guard Self.apply(plans, to: &result.plans, id: \.id, undo: undo),
              Self.apply(
                manualActuals,
                to: &result.actuals,
                id: \.id,
                undo: undo
              ) else {
            return nil
        }

        for change in corrections {
            let expected = undo ? change.after : change.before
            guard result.settings.activityCorrections[change.id] == expected
            else { return nil }
        }
        for change in corrections {
            let replacement = undo ? change.before : change.after
            result.settings.activityCorrections[change.id] = replacement
        }

        let labelsToAdd = undo ? removedLabels : addedLabels
        let labelsToRemove = undo ? addedLabels : removedLabels
        result.settings.customActivityLabels = Self.applyingSetChanges(
            to: result.settings.customActivityLabels,
            adding: labelsToAdd,
            removing: labelsToRemove
        )

        let spansToAdd = undo ? removedSleepSpans : addedSleepSpans
        let spansToRemove = undo ? addedSleepSpans : removedSleepSpans
        result.settings.confirmedSleepSpans = Self.applyingSetChanges(
            to: result.settings.confirmedSleepSpans,
            adding: spansToAdd,
            removing: spansToRemove
        ).sorted { $0.start < $1.start }

        let suppressedToAdd = undo ? removedSuppressedIDs : addedSuppressedIDs
        let suppressedToRemove = undo ? addedSuppressedIDs : removedSuppressedIDs
        result.settings.suppressedActualIDs.formUnion(suppressedToAdd)
        result.settings.suppressedActualIDs.subtract(suppressedToRemove)
        if !corrections.isEmpty {
            result.actuals = ActivityCorrectionEngine.applying(
                result.settings.activityCorrections,
                to: result.actuals
            ).sorted { $0.startedAt < $1.startedAt }
        } else if !manualActuals.isEmpty {
            result.actuals.sort { $0.startedAt < $1.startedAt }
        }
        result.plans.sort { $0.span.start < $1.span.start }
        return result
    }

    func mergingPlanChanges(with next: Self) -> Self? {
        guard !plans.isEmpty,
              manualActuals.isEmpty, next.manualActuals.isEmpty,
              corrections.isEmpty, next.corrections.isEmpty,
              addedLabels.isEmpty, next.addedLabels.isEmpty,
              removedLabels.isEmpty, next.removedLabels.isEmpty,
              addedSleepSpans.isEmpty, next.addedSleepSpans.isEmpty,
              removedSleepSpans.isEmpty, next.removedSleepSpans.isEmpty,
              addedSuppressedIDs.isEmpty, next.addedSuppressedIDs.isEmpty,
              removedSuppressedIDs.isEmpty, next.removedSuppressedIDs.isEmpty,
              Set(plans.map(\.id)) == Set(next.plans.map(\.id)) else {
            return nil
        }
        let nextByID = Dictionary(next.plans.map {
            ($0.id, $0)
        }, uniquingKeysWith: { first, _ in first })
        let combined = plans.compactMap { first -> AppModelHistoryChange<PlanRecord>? in
            guard let latest = nextByID[first.id],
                  first.before != latest.after else { return nil }
            return AppModelHistoryChange(
                id: first.id,
                before: first.before,
                after: latest.after
            )
        }
        guard !combined.isEmpty else { return nil }
        return Self(
            plans: combined,
            manualActuals: [],
            corrections: [],
            addedLabels: [],
            removedLabels: [],
            addedSleepSpans: [],
            removedSleepSpans: [],
            addedSuppressedIDs: [],
            removedSuppressedIDs: []
        )
    }

    private static func changes<Value: Hashable>(
        from before: [Value],
        to after: [Value],
        id: KeyPath<Value, UUID>,
        include: (Value) -> Bool
    ) -> [AppModelHistoryChange<Value>] {
        let oldByID = Dictionary(
            before.filter(include).map { ($0[keyPath: id], $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let newByID = Dictionary(
            after.filter(include).map { ($0[keyPath: id], $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return Set(oldByID.keys).union(newByID.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                let old = oldByID[id]
                let new = newByID[id]
                guard old != new else { return nil }
                return AppModelHistoryChange(id: id, before: old, after: new)
            }
    }

    private static func dictionaryChanges<Value: Hashable>(
        from before: [UUID: Value],
        to after: [UUID: Value]
    ) -> [AppModelHistoryChange<Value>] {
        Set(before.keys).union(after.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                let old = before[id]
                let new = after[id]
                guard old != new else { return nil }
                return AppModelHistoryChange(id: id, before: old, after: new)
            }
    }

    private static func apply<Value: Hashable>(
        _ changes: [AppModelHistoryChange<Value>],
        to values: inout [Value],
        id: KeyPath<Value, UUID>,
        undo: Bool
    ) -> Bool {
        var currentByID: [UUID: Value] = [:]
        for value in values {
            currentByID[value[keyPath: id]] = value
        }
        for change in changes {
            let expected = undo ? change.after : change.before
            guard currentByID[change.id] == expected else { return false }
        }
        for change in changes {
            let replacement = undo ? change.before : change.after
            if let index = values.firstIndex(where: {
                $0[keyPath: id] == change.id
            }) {
                if let replacement {
                    values[index] = replacement
                } else {
                    values.remove(at: index)
                }
            } else if let replacement {
                values.append(replacement)
            }
        }
        return true
    }

    private static func applyingSetChanges<Value: Hashable>(
        to values: [Value],
        adding: Set<Value>,
        removing: Set<Value>
    ) -> [Value] {
        var result = values.filter { !removing.contains($0) }
        for value in adding where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}

private struct AppModelHistoryItem {
    let id = UUID()
    let entry: AppModelHistoryEntry
    let coalescingKey: String?
    var recordedAt: Date
}

@MainActor
@Observable
final class AppModel {
    private(set) static weak var applicationInstance: AppModel?

    static func backgroundTaskInstance() -> AppModel {
        if let applicationInstance { return applicationInstance }
        // Every UI-less wake builds a whole model; record the cost so the
        // decision to keep one alive rests on measured time, not a guess.
        let started = ContinuousClock.now
        let model = AppModel(registersHealthBackgroundHandler: false)
        applicationInstance = model
        let elapsed = started.duration(to: .now).components
        TaptionPlanDiagnosticsLogger.shared.record(
            "background_model_created",
            fields: ["init_ms": String(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)]
        )
        return model
    }

    private static let integrationLogger = Logger(
        subsystem: "com.taption.plan",
        category: "AutomaticRecords"
    )
    private static let mapLocationReadingTimeout: TimeInterval = 3
    private static let weatherPreviewRefreshInterval: TimeInterval = 30 * 60
    private static let weatherPreviewMaximumDays = 7
    /// 지난 날 날씨 고정: 한 번에 거슬러 가는 최대 일수와 시도 간격.
    private static let weatherFixBackfillDays = 3
    private static let weatherFixRetryInterval: TimeInterval = 30 * 60
    private static let weatherFixedThroughDayKey = "taption.weather.fixed-through-day-v1"
    var selectedTab: RootTab = .schedule
    var selectedScale: TimeScale = .day
    var selectedDate: Date = .now {
        didSet {
            guard !Calendar.autoupdatingCurrent.isDate(
                oldValue, inSameDayAs: selectedDate
            ) else { return }
            scheduleSelectedDateRefresh()
        }
    }
    var isAddPlanPresented = false
    var addPlanContext: AddPlanContext = .quick
    var selectedAction: QuickActionItem?
    var planEditorRequest: PlanEditorRequest?
    var selectedPhotoCluster: PhotoCluster?
    var detail: AppDetail?
    var selectedGroupPlanID: UUID?
    var selectedGoalPlanID: UUID?
    var groupNavigationPath: [UUID] = []
    /// 메모 입력은 항목을 먼저 고르지 않는다. 시간표 메모 줄에서 바로 열리며,
    /// 새 메모가 놓일 순간과 그 자리에 이미 있던 메모만 들고 있으면 된다.
    private(set) var memoEntry: MemoEntry?
    var selectedCatCoat: CatCoat = .calico
    /// 기록 탭은 시간표와 같은 배율을 쓰되, 기록 전용 년 보기는 유지한다.
    var reviewScale: TimeScale = .week
    var isPermissionOnboardingPresented = false
    private(set) var permissionOnboardingStartFeature: PermissionFeature?
    private(set) var pendingSetupCategoryIDs: Set<String> = []
    private(set) var isEditingSetupCategories = false

    private(set) var snapshot: TaptionDataSnapshot = .empty {
        didSet {
            if isRevertingSnapshotAfterRepositoryFailure { return }
            if repositoryLoadFailed || isStartupSnapshotPartial {
                isRevertingSnapshotAfterRepositoryFailure = true
                timestampOnlySnapshotAssignment = false
                snapshot = oldValue
                isRevertingSnapshotAfterRepositoryFailure = false
                return
            }
            if timestampOnlySnapshotAssignment {
                timestampOnlySnapshotAssignment = false
                if oldValue.updatedAt != snapshot.updatedAt {
                    snapshotRevision &+= 1
                    activityClassificationRevisionFence.advance(to: snapshotRevision)
                }
                return
            }
            if oldValue == snapshot {
                timestampOnlySnapshotAssignment = false
                return
            }
            snapshotRevision &+= 1
            activityClassificationRevisionFence.advance(to: snapshotRevision)

            // Device snapshots are frequent. Keep a separate revision for
            // changes that alter rows, blocks or their detail targets so the
            // Gantt layout cache survives ordinary live collection.
            if oldValue.actuals != snapshot.actuals
                || oldValue.places != snapshot.places
                || oldValue.travel != snapshot.travel {
                dayProjectionRevision &+= 1
                needsLocalRecordNormalization = true
            }
            if oldValue.settings.activityCorrections != snapshot.settings.activityCorrections
                || oldValue.settings.confirmedSleepSpans != snapshot.settings.confirmedSleepSpans {
                needsLocalRecordNormalization = true
            }
            if oldValue.weather != snapshot.weather
                || oldValue.plans != snapshot.plans
                || oldValue.actuals != snapshot.actuals
                || oldValue.travel != snapshot.travel
                || oldValue.places != snapshot.places
                || oldValue.calendarEvents != snapshot.calendarEvents
                || oldValue.photos != snapshot.photos
                || oldValue.categories != snapshot.categories
                || oldValue.recordLinks != snapshot.recordLinks
                || oldValue.memos != snapshot.memos
                || oldValue.settings.timelineRowOrder
                    != snapshot.settings.timelineRowOrder {
                timelineRevision &+= 1
            }
        }
    }
    @ObservationIgnored private(set) var snapshotRevision: UInt64 = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var userEditUndoHistory: [AppModelHistoryItem] = []
    @ObservationIgnored private var userEditRedoHistory: [AppModelHistoryItem] = []
    @ObservationIgnored private let activityClassificationRevisionFence =
        ActivityClassificationRevisionFence()
    @ObservationIgnored private(set) var dayProjectionRevision: UInt64 = 0
    private(set) var rawDayRevisionSignal: UInt64 = 0
    @ObservationIgnored private var rawDayRevisions: [Date: UInt64] = [:]
    @ObservationIgnored private var daySourceFingerprintCache = TaptionBoundedCache<
        Date, (revision: UInt64, value: String?)
    >(capacity: 42)
    @ObservationIgnored private(set) var timelineRevision: UInt64 = 0
    private(set) var backupRestoreRevision: UInt64 = 0
    @ObservationIgnored private var timestampOnlySnapshotAssignment = false
    @ObservationIgnored private var isRevertingSnapshotAfterRepositoryFailure =
        false
    @ObservationIgnored private var needsLocalRecordNormalization = true
    private(set) var isBootstrapped = false
    private(set) var hasPreparedStartupSettings = false
    @ObservationIgnored private var isStartupSnapshotPartial = false
    /// 저장소를 읽지 못한 상태에서 빈 스냅샷을 저장하면 기존 기록을
    /// 덮어쓸 수 있다. 복구 가능한 저장본을 다시 읽기 전까지 저장을 막는다.
    @ObservationIgnored private var repositoryLoadFailed = false
    @ObservationIgnored private var pendingMapMemoIDs = Set<UUID>()
    private(set) var isRefreshingIntegrations = false
    private(set) var isRequestingPermission = false
    private(set) var isSensorCollecting = false
    private(set) var sensorStorageErrorDescription: String?
    private(set) var sensorCollectionSessionState: SensorCollectionSessionState =
        .stopped
    private(set) var sensorCollectionSessionID: UUID?
    private(set) var sensorCollectionStartedAt: Date?
    private(set) var lastSensorWakeReason: SensorWakeReason?
    private(set) var lastSensorSavedAt: Date?
    private(set) var sensorSaveToken = 0
    private(set) var isCloudSyncing = false
    private(set) var isExportingDiagnostics = false
    private(set) var diagnosticsExportStatus = AppLanguagePreference.text(
        korean: "준비됨",
        english: "Ready"
    )
    private(set) var cloudUnavailableReason: CloudUnavailableReason?
    private(set) var isRecordingVoiceMemo = false
    private(set) var playingVoiceAttachmentID: UUID?
    private(set) var sensorAvailability: SensorHardwareAvailability?
    private(set) var latestSensorReading: SensorReading?
    private(set) var latestHeartRate: Double?
    private(set) var latestHeartRateUpdatedAt: Date?
    private var latestMapAnchorHydratedDay: Date?
    private(set) var liveRouteState: LiveRouteState = .empty
    private(set) var activeTrackingSession: TrackingSession?
    private(set) var trackingSessionWasRecovered = false
    private(set) var latestAltitudeEstimate: CalibratedAltitudeEstimate?
    private(set) var floorCalibrationNotice: String? = nil
    /// 층 보정 표본을 모으는 중일 때만 값이 있다. 화면은 이 값으로 진행을
    /// 보여 주고, 끝나기 전에는 아무것도 기록되지 않는다.
    private(set) var floorCalibrationSampling: FloorCalibrationSampling?
    private(set) var watchLaunchReport: (report: String, receivedAt: Date)?
    /// 등록하지 않았는데 자주 간 자리 하나. 설정 화면을 열 때만 다시 구하고,
    /// 한 번에 하나만 보여 준다.
    private(set) var frequentPlaceSuggestion: FrequentPlaceSuggestion?
    private(set) var sleepSessions: [SleepSession] = []
    private(set) var lastHealthRefreshAt: Date?
    private(set) var healthSyncOverview = HealthKitSyncOverview(states: [])
    private(set) var healthSyncProgress: HealthKitSyncProgress?
    private(set) var isHealthHistorySyncRunning = false
    private(set) var appleWatchConnectionState: AppleWatchConnectionState = .unsupported
    private(set) var appleWatchLastDataReceivedAt: Date?
    private(set) var appleWatchReceivedDataKinds: Set<AppleWatchDataKind> = []
    private(set) var appleWatchDataSyncRequestedAt: Date?
    private(set) var appleWatchDataSyncRequestStatus:
        AppleWatchDataSyncRequestStatus?
    @ObservationIgnored private var appleWatchDataSyncRequestID: String?
    /// 첫 실행 안내를 닫은 기록. 기기 저장소에서 읽어 오고, 바뀔 때만 다시
    /// 넣어 화면이 갱신되게 한다.
    private(set) var dismissedAppleWatchPrompts: Set<AppleWatchOnboardingPrompt> =
        AppleWatchOnboardingStore().dismissed
    private(set) var hasSeenWatchAppInstalled =
        AppleWatchOnboardingStore().hasSeenWatchAppInstalled
    @ObservationIgnored
    private let watchOnboardingStore = AppleWatchOnboardingStore()
    @ObservationIgnored
    private let appleWatchDataReceiptStore: AppleWatchDataReceiptStore
    private(set) var appUsageAuthorizationState: ScreenTimeAuthorizationState = .unavailable
    private(set) var lastAppUsageRefreshAt: Date?
    private(set) var appUsageRecordCount = 0
    private(set) var appUsageTotalDuration: TimeInterval = 0
    private(set) var biometricDataProtectionStatus: BiometricDataProtectionStatus =
        .notProtected
    /// Cloud-backup PIN and the optional local app-lock gate are independent:
    /// normal planning remains usable when no security credential is set.
    private(set) var securityStatus = PlanSecurityStatus(
        settings: PlanAppLockSettings(),
        state: .unlocked,
        hasPIN: false,
        failedAttempts: 0,
        retryAfter: nil,
        latestSuccessfulBackupDate: nil
    )
    private(set) var backupActivity: PlanBackupActivity = .idle
    private(set) var backupListings: [PlanBackupListingRow] = []
    private(set) var backupListingError: String?
    private(set) var lastBackupReport: PlanBackupReport?
    /// 기록 ID → 앱 토큰. 스크린 타임 데이터는 민감하므로 저장하지 않고
    /// 새로 고칠 때마다 메모리에만 채운다.
    private(set) var appUsageTokenIndex: [UUID: Data] = [:]
    var userFacingError: String?
    @ObservationIgnored private var lastAutoFloorCalibrationKey: String? = nil
    @ObservationIgnored private var altitudeSpikeGate = AltitudeSpikeGate()
    @ObservationIgnored private var altitudeGatePlaceID: UUID? = nil
    @ObservationIgnored private var calibrationNoticeTask: Task<Void, Never>?

    var widgetSyncStatus: TaptionWidgetSyncStatus {
        TaptionWidgetSyncStatus.compare(
            groundTruth: TaptionWidgetSharedStore.readGroundTruthPayload(),
            cached: TaptionWidgetSharedStore.readPayload()
        )
    }

    var widgetSyncStatusText: String {
        widgetSyncStatus.displayName
    }

    var widgetSyncDiagnosticsText: String {
        TaptionWidgetSharedStore.diagnostics().summary
    }

    var diagnosticsLatestLogSummary: String {
        let defaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ) ?? .standard
        guard let fileName = defaults.string(
            forKey: Self.diagnosticsLatestFileKey
        ),
        let savedAt = defaults.object(
            forKey: Self.diagnosticsLatestSavedAtKey
        ) as? Date else {
            return AppLanguagePreference.text(
                korean: "최신 로그 없음",
                english: "No recent log"
            )
        }
        let savedText = savedAt.formatted(date: .abbreviated, time: .shortened)
        return AppLanguagePreference.text(
            korean: "최신 \(fileName) · \(savedText)",
            english: "Latest \(fileName) · \(savedText)"
        )
    }

    var appUsageStatusText: String {
        guard appUsageAuthorizationState == .approved else {
            return appUsageAuthorizationState.displayName
        }
        guard lastAppUsageRefreshAt != nil else {
            return AppLanguagePreference.text(
                korean: "동기화 대기",
                english: "Waiting to sync"
            )
        }
        guard let total = ScreenTimeUsageRecordEngine
            .localizedDurationText(appUsageTotalDuration) else {
            return AppLanguagePreference.text(
                korean: "오늘 기록 없음",
                english: "No records today"
            )
        }
        return AppLanguagePreference.text(
            korean: "오늘 \(total) · \(appUsageRecordCount)개",
            english: "Today \(total) · \(appUsageRecordCount) items"
        )
    }

    var cloudStatusText: String {
        if isCloudSyncing {
            return AppLanguagePreference.text(korean: "동기화 중", english: "Syncing")
        }
        if let cloudUnavailableReason { return cloudUnavailableReason.statusLabel }
        return permissionState(for: .cloud).settingsLabel
    }

    var cloudStatusGuidance: String? {
        isCloudSyncing ? nil : cloudUnavailableReason?.guidance
    }

    /// 자동 기록이 하나도 없고 필요한 연동이 꺼져 있을 때만 알린다. 연동은
    /// 켜져 있는데 보이는 구간에만 기록이 없는 경우는 정상이므로 알리지
    /// 않는다.
    var timelineIntegrationNotice: [String]? {
        guard snapshot.actuals.isEmpty,
              snapshot.travel.isEmpty,
              snapshot.places.isEmpty,
              snapshot.calendarEvents.isEmpty,
              snapshot.photos.isEmpty,
              snapshot.plans.isEmpty else {
            return nil
        }
        var missing: [String] = []
        if !settings.locationEnabled
            || !permissionState(for: .location).isGranted {
            missing.append(AppLanguagePreference.text(
                korean: "위치·이동",
                english: "Location & movement"
            ))
        }
        if !settings.healthEnabled {
            missing.append(AppLanguagePreference.text(
                korean: "건강 데이터",
                english: "Health data"
            ))
        }
        if settings.selectedCalendarIDs.isEmpty {
            missing.append(AppLanguagePreference.text(
                korean: "캘린더",
                english: "Calendar"
            ))
        }
        return missing.isEmpty ? nil : missing
    }

    var needsSleepConnectionNotice: Bool {
        guard selectedScale == .day,
              !settings.healthEnabled,
              Calendar.autoupdatingCurrent.isDateInToday(selectedDate) else {
            return false
        }
        let today = daySpan(containing: selectedDate)
        return !snapshot.actuals.contains {
            ($0.categoryID == "sleep"
                || $0.behavior == WatchBehaviorKind.sleep.rawValue)
                && $0.span(asOf: today.end).intersection(with: today) != nil
        }
    }

    @ObservationIgnored private let repository: any PlanDataRepository
    @ObservationIgnored private let biometricProtectedSnapshotStore:
        BiometricProtectedSnapshotStore?
    @ObservationIgnored private let calendarService: AppleCalendarService
    @ObservationIgnored private let photoService: ApplePhotoLibraryService
    @ObservationIgnored private let healthService: AppleHealthService
    @ObservationIgnored private let sensorService: AppleSensorDataService?
    @ObservationIgnored private let weatherService: AppleWeatherContextService
    /// 날씨를 못 가져온 이유를 화면에 보여주기 위한 상태(값이 바뀔 때만 갱신한다).
    private(set) var weatherStatus = WeatherServiceStatus()
    @ObservationIgnored private let airQualityService: AirQualityContextService
    @ObservationIgnored private let cloudSyncService: CloudKitSnapshotSyncService?
    @ObservationIgnored private let securityService: PlanSecurityService?
    @ObservationIgnored private let backupService: PlanBackupEngineAdapter?
    @ObservationIgnored private let placeNameResolver: PlaceNameResolver
    @ObservationIgnored private let transportContextService:
        AppleTransportContextService
    @ObservationIgnored private let voiceMemoRecorder: VoiceMemoRecorder
    @ObservationIgnored private let voiceMemoPlayer: VoiceMemoPlayer
    @ObservationIgnored private let liveActivityController: TaptionLiveActivityController
    @ObservationIgnored private let notificationScheduler: PlanNotificationScheduler
    @ObservationIgnored private let watchConnectivityService: AppleWatchConnectivityService
    @ObservationIgnored private let airPodsActivityService: AirPodsActivityService
    @ObservationIgnored private let screenTimeUsageService: ScreenTimeUsageService
    @ObservationIgnored private let rawDeviceDataArchive:
        RawDeviceDataDayArchive?
    @ObservationIgnored private let dayDatabase: PlanDayDatabase?
    @ObservationIgnored private let dayLoadCoordinator: PlanDayLoadCoordinator?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var startupSettingsTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var permissionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsBootstrapPreparation = false
    @ObservationIgnored private var foregroundPreparationTask:
        Task<Void, Never>?
    @ObservationIgnored private var foregroundPreparationGeneration = 0
    @ObservationIgnored private var foregroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var deferredVisibleRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastForegroundRefreshAt: Date?
    @ObservationIgnored private var foregroundHealthRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored private var calendarStoreRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored private var calendarStoreRefreshRequiresWide = false
    @ObservationIgnored private var selectedDateRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored private var selectedDateRefreshGeneration = 0
    @ObservationIgnored private var widgetReloadFollowupTask:
        Task<Void, Never>?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private(set) var isCommerceLocked = false
    @ObservationIgnored private var isHealthRefreshRunning = false
    @ObservationIgnored private var isSensorTimelineRefreshing = false
    /// A user edit saved while a sensor refresh was running. Rolling the whole
    /// snapshot back to the pre-refresh copy would silently delete that edit.
    @ObservationIgnored private var userEditedDuringSensorRefresh = false
    @ObservationIgnored private var isDeletingUserData = false
    @ObservationIgnored private var dataDeletionGeneration =
        TaptionDataDeletionFence.currentGeneration()
    @ObservationIgnored private var repositoryWriteTask: Task<Bool, Error>?
    @ObservationIgnored private var repositoryWriteSequence: UInt64 = 0
    @ObservationIgnored private var sensorTimelineTask: Task<Bool, Never>?
    @ObservationIgnored private var sensorTimelineRequestID: UUID?
    @ObservationIgnored private var sensorTimelineRequestKey: String?
    @ObservationIgnored private var postSaveRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var postSaveRefreshRequested = false
    @ObservationIgnored private var activeDataMutationCount = 0
    @ObservationIgnored private var lastWatchHealthSnapshotCapturedAt: Date?
    @ObservationIgnored private var lastWatchHealthSnapshotRawRetryAt: Date?
    @ObservationIgnored private var lastWatchHealthSnapshotRawRetryFingerprint:
        String?
    @ObservationIgnored private var lastWatchHealthSnapshotRawRetryAttemptAt:
        Date?
    @ObservationIgnored private var isAppUsageRefreshRunning = false
    @ObservationIgnored private var isHealthBackgroundDeliveryConfigured = false
    @ObservationIgnored private var sensorAnalysisDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var sensorAnalysisTaskGeneration = 0
    @ObservationIgnored private let sensorAnalysisDebounceDelay: Duration
    @ObservationIgnored private var sensorAnalysisRequestRevision: UInt64 = 0
    @ObservationIgnored private var pendingSensorAnalysisRevisions: [Date: UInt64] = [:]
    @ObservationIgnored private var finalizedTrackingSessionIDs = Set<UUID>()
    @ObservationIgnored private var latestWatchSummaryVersion:
        [UUID: WatchSummaryVersion] = [:]
    @ObservationIgnored private var appliedWatchSummaryVersion:
        [UUID: WatchSummaryVersion] = [:]
    @ObservationIgnored private var restoredWatchSummarySessions = Set<UUID>()
    @ObservationIgnored private var finalizedWatchSummarySessionIDs = Set<UUID>()
    @ObservationIgnored private var liveWeatherRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveEnvironmentPoint: GeoPoint?
    @ObservationIgnored private var lastLiveEnvironmentAt: Date?
    @ObservationIgnored private var lastLiveEnvironmentFailureAt: Date?
    @ObservationIgnored private var lastFutureWeatherRefreshAt: Date?
    @ObservationIgnored private var lastFutureWeatherPoint: GeoPoint?
    @ObservationIgnored private var weatherFixTask: Task<Void, Never>?
    @ObservationIgnored private var lastWeatherFixAttemptAt: Date?
    @ObservationIgnored private var lastTrackingSessionRecoveryPersistAt: Date?
    @ObservationIgnored private var lastDeviceSnapshotPersistAt: Date?
    @ObservationIgnored private var lastReviewArchiveRefreshAt: Date?
    @ObservationIgnored private var lastReviewArchiveRefreshRevision: UInt64?
    @ObservationIgnored private var pendingWatchActivitySuggestion:
        TaptionWatchActivitySuggestion?
    @ObservationIgnored private var pendingDeviceLocalPersistTask: Task<Void, Never>?
    @ObservationIgnored private var cloudSyncTask: Task<Void, Never>?
    @ObservationIgnored private var liveMergeCacheKey: LiveMergeCacheKey?
    @ObservationIgnored private var liveMergeCacheValue: [SensorReading] = []
    @ObservationIgnored private var sensorRefreshFingerprints:
        [Date: SensorRefreshFingerprint] = [:]
    @ObservationIgnored private var integrationRefreshGate =
        TimelineIntegrationRefreshGate()
    @ObservationIgnored private var integrationRefreshSkipCount = 0
    @ObservationIgnored private var lastIntegrationSkipLogUptime: TimeInterval = 0
    @ObservationIgnored private var lastWidgetPayloadIdentity:
        TaptionWidgetPayload?
    @ObservationIgnored private var lastWatchPayloadIdentity:
        TaptionWatchPayload?
    @ObservationIgnored private var widgetPayloadSkipCount = 0
    @ObservationIgnored private var watchPayloadSkipCount = 0
    @ObservationIgnored private var lastWidgetSkipLogUptime: TimeInterval = 0
    @ObservationIgnored private var lastWatchSkipLogUptime: TimeInterval = 0
    @ObservationIgnored private let sensorBackgroundCoordinator =
        SensorBackgroundCoordinator.shared

    // Keep the live route bounded without shifting the whole array on every
    // GPS tick.  Trimming in batches makes long running sessions amortized
    // O(1) per append while preserving the same 4,000-point render limit.
    private static let liveRouteHardLimit = 4_000
    private static let liveRouteSoftLimit = 4_512

    private static let permissionOnboardingKey =
        "taption.permission-onboarding.v1"
    private static let healthAuthorizationRequestedKey =
        "taption.health-authorization-requested.v1"
    private static let healthPermissionReminderKey =
        "taption.health-permission-reminder.v1"
    private static let watchDataSyncProfileConfiguredKey =
        "taption.watch-data-sync-profile-configured.v1"
    private static let watchSummaryHighWaterKeyPrefix =
        "taption.watch-summary-high-water.v1."
    private static let watchSummaryAppliedHighWaterKeyPrefix =
        "taption.watch-summary-applied-high-water.v1."
    private static let permissionFlagsMigrationKey =
        "taption.permission-flags-sync.v2"
    private static let calendarAutomaticRefreshKey =
        "taption.calendar-automatic-refresh.v1"
    private static let diagnosticsLatestFileKey =
        "taption.diagnostics.latest.file.v1"
    private static let diagnosticsLatestSavedAtKey =
        "taption.diagnostics.latest.saved-at.v1"

    private struct LiveMergeCacheKey: Equatable {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
        let archivedCount: Int
        let archivedFirstID: UUID?
        let archivedLastID: UUID?
        let archivedFirstTimestamp: Date?
        let archivedLastTimestamp: Date?
        let liveCount: Int
        let liveLastUpdatedAt: Date?
    }

    private struct SensorRefreshFingerprint: Hashable {
        let readingCount: Int
        let latestReadingID: UUID?
        let latestMotionEnd: Date?
        let motionHash: Int
        let pedometerEnd: Date?
        let pedometerHash: Int?
        let latestHealthEvidenceEnd: Date?
        let healthEvidenceHash: Int
        let watchSummaryCount: Int
        let latestWatchSummaryEnd: Date?
        let watchAccelerationSampleCount: Int
        let latestWatchAccelerationSampleAt: Date?
        let transportEnrichmentModelVersion: Int
        let settingsHash: Int
    }

    init(
        repository: (any PlanDataRepository)? = nil,
        calendarService: AppleCalendarService? = nil,
        photoService: ApplePhotoLibraryService = ApplePhotoLibraryService(),
        healthService: AppleHealthService = .shared,
        sensorService: AppleSensorDataService? = nil,
        weatherService: AppleWeatherContextService =
            AppleWeatherContextService(),
        airQualityService: AirQualityContextService =
            AirQualityContextService(),
        cloudSyncService: CloudKitSnapshotSyncService? =
            CloudKitSnapshotSyncService.automatic(),
        placeNameResolver: PlaceNameResolver = PlaceNameResolver(),
        transportContextService: AppleTransportContextService? = nil,
        voiceMemoRecorder: VoiceMemoRecorder? = nil,
        voiceMemoPlayer: VoiceMemoPlayer? = nil,
        liveActivityController: TaptionLiveActivityController =
            TaptionLiveActivityController(),
        notificationScheduler: PlanNotificationScheduler =
            PlanNotificationScheduler(),
        watchConnectivityService: AppleWatchConnectivityService =
            AppleWatchConnectivityService(),
        airPodsActivityService: AirPodsActivityService =
            AirPodsActivityService(),
        screenTimeUsageService: ScreenTimeUsageService? = nil,
        securityService: PlanSecurityService? = nil,
        backupEngine: TaptionBackupEngine? = nil,
        rawDeviceDataArchive: RawDeviceDataDayArchive? = nil,
        appleWatchDataReceiptStore: AppleWatchDataReceiptStore =
            AppleWatchDataReceiptStore(),
        registersHealthBackgroundHandler: Bool = true,
        startsCommerceLocked: Bool = false,
        dayDatabase: PlanDayDatabase? = nil,
        sensorAnalysisDebounceDelay: Duration = .seconds(120)
    ) {
        isCommerceLocked = startsCommerceLocked
        self.sensorAnalysisDebounceDelay = sensorAnalysisDebounceDelay
        let repositorySource: String
        if let repository {
            self.repository = repository
            repositorySource = "injected"
        } else {
            let selection: PlanRepositorySelection
            if let store = try? TaptionStoreV2.applicationSupport() {
                selection = PlanRepositorySelection(
                    repository: TaptionStoreRepository(store: store),
                    source: "taption-store"
                )
            } else {
                selection = PlanRepositorySelection(
                    repository: UnavailablePlanRepository(),
                    source: "unavailable"
                )
            }
            self.repository = selection.repository
            repositorySource = selection.source
        }
        let protectionStore = try? BiometricProtectedSnapshotStore.applicationSupport()
        self.biometricProtectedSnapshotStore = protectionStore
        self.biometricDataProtectionStatus = protectionStore?.status ?? .unavailable
        let rawArchive = rawDeviceDataArchive
            ?? (try? RawDeviceDataDayArchive.applicationSupport())
        self.calendarService = calendarService ?? AppleCalendarService()
        self.photoService = photoService
        self.healthService = healthService
        if let sensorService {
            self.sensorService = sensorService
            self.sensorStorageErrorDescription = nil
        } else {
            do {
                self.sensorService = try AppleSensorDataService.applicationSupport()
                self.sensorStorageErrorDescription = nil
            } catch {
                self.sensorService = nil
                self.sensorStorageErrorDescription = error.localizedDescription
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_archive_initialization_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error)
                )
            }
        }
        self.weatherService = weatherService
        self.airQualityService = airQualityService
        self.cloudSyncService = cloudSyncService
        self.securityService = securityService ?? PlanSecurityService()
        if let backupEngine {
            self.backupService = PlanBackupEngineAdapter(engine: backupEngine)
        } else if repository == nil, let store = try? TaptionStoreV2.applicationSupport() {
            self.backupService = PlanBackupEngineAdapter(
                engine: TaptionBackupEngine(store: store, destination: TaptionICloudDriveBackupDestination()))
        } else {
            self.backupService = nil
        }
        self.securityStatus = self.securityService?.status ?? PlanSecurityStatus(
            settings: PlanAppLockSettings(), state: .unlocked, hasPIN: false,
            failedAttempts: 0, retryAfter: nil,
            latestSuccessfulBackupDate: nil
        )
        self.placeNameResolver = placeNameResolver
        self.transportContextService = transportContextService
            ?? AppleTransportContextService()
        self.voiceMemoRecorder = voiceMemoRecorder ?? VoiceMemoRecorder()
        self.voiceMemoPlayer = voiceMemoPlayer ?? VoiceMemoPlayer()
        self.liveActivityController = liveActivityController
        self.notificationScheduler = notificationScheduler
        self.watchConnectivityService = watchConnectivityService
        self.appleWatchDataReceiptStore = appleWatchDataReceiptStore
        self.airPodsActivityService = airPodsActivityService
        self.screenTimeUsageService =
            screenTimeUsageService ?? ScreenTimeUsageService()
        self.appUsageAuthorizationState =
            self.screenTimeUsageService.authorizationState
        self.rawDeviceDataArchive = rawArchive
        let resolvedDayDatabase = dayDatabase
            ?? (try? PlanDayDatabase.applicationSupport())
        self.dayDatabase = resolvedDayDatabase
        self.dayLoadCoordinator = PlanDayLoadCoordinator()
        let watchReceipt = appleWatchDataReceiptStore.load()
        self.appleWatchLastDataReceivedAt = watchReceipt.latestDataAt
        self.appleWatchReceivedDataKinds = watchReceipt.recentKinds()
        Self.integrationLogger.notice(
            "Repository selected: \(repositorySource, privacy: .public)"
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "app_model_initialized",
            fields: ["repository": repositorySource]
        )
        self.voiceMemoPlayer.onFinish = { [weak self] in
            self?.playingVoiceAttachmentID = nil
        }
        self.sensorService?.onLiveReadingPreview = { [weak self] reading in
            Task { @MainActor [weak self] in
                self?.applyLiveReadingPreview(reading)
            }
        }
        self.sensorService?.onReadingsPersisted = { [weak self] readings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = readings.filter {
                    self.acceptsDataMutation(capturedAt: $0.timestamp)
                }
                guard !accepted.isEmpty else { return }
                self.sensorStorageErrorDescription = nil
                self.invalidateRawDays(accepted.map(\.timestamp))
                self.handlePersistedSensorReadings(accepted)
            }
        }
        self.sensorService?.onPersistenceFailed = { [weak self] description in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsDataMutation() else { return }
                self.sensorStorageErrorDescription = description
                self.isSensorCollecting = false
                self.sensorBackgroundCoordinator.endSession()
                self.syncSensorBackgroundState()
            }
        }
        self.watchConnectivityService.activate(
            onCommand: { [weak self] command in
                Task { @MainActor [weak self] in
                    await self?.applyWatchCommand(command)
                }
            },
            onSensorSummary: { [weak self] summary, receivedAt, requestID, deliveryID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let persisted = await self.applyWatchSensorSummary(
                        summary,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                    if persisted, let deliveryID {
                        self.watchConnectivityService
                            .acknowledgeAmbientDelivery(deliveryID)
                    }
                }
            },
            onAccelerationChunk: { [weak self] chunk, receivedAt, requestID, deliveryID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let persisted = await self.applyWatchAccelerationChunk(
                        chunk,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                    if persisted, let deliveryID {
                        self.watchConnectivityService
                            .acknowledgeAmbientDelivery(deliveryID)
                    }
                }
            },
            onHealthSnapshot: { [weak self] snapshot, receivedAt, requestID in
                Task { @MainActor [weak self] in
                    await self?.applyWatchHealthSnapshot(
                        snapshot,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                }
            },
            onActivityConfirmation: { [weak self] confirmation, receivedAt in
                Task { @MainActor [weak self] in
                    await self?.applyWatchActivityConfirmation(
                        confirmation,
                        receivedAt: receivedAt
                    )
                }
            },
            // Watch settings are owned by the iPhone. Older Watch builds may
            // still send a location toggle; ignore it and restore the iPhone
            // value instead of letting the Watch mutate app settings.
            onLocationTracking: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsDataMutation() else { return }
                    await self.bootstrap()
                    guard self.acceptsDataMutation() else { return }
                    self.publishWatchPayload()
                }
            },
            onStatusChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.applyAppleWatchConnectionState(state)
                }
            },
            onDataSyncLiveFailure: { [weak self] requestID in
                Task { @MainActor [weak self] in
                    self?.applyAppleWatchDataSyncLiveFailure(
                        requestID: requestID
                    )
                }
            }
        )
        if registersHealthBackgroundHandler {
            Self.applicationInstance = self
            Task { [weak self] in
                await HealthBackgroundRefreshCoordinator.shared.register {
                    [weak self] in
                    guard let self else { return false }
                    await self.handleObservedHealthChange()
                    return true
                }
            }
        }
    }

    var showsBottomBar: Bool {
        true
    }

    var settings: AppFeatureSettings {
        snapshot.settings
    }

    func refreshBiometricDataProtectionStatus() {
        biometricDataProtectionStatus = biometricProtectedSnapshotStore?.status
            ?? .unavailable
    }

    var isAppLocked: Bool {
        if case .locked = securityStatus.state { return true }
        return false
    }

    /// 이 기기에 보관된 6자리 비밀번호. 백업·복원·로컬 정리에 쓰며, 없으면 한 번 입력받는다.
    var rememberedBackupPassword: String? { securityService?.rememberedPassword }

    func configureBackupPIN(_ pin: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        try securityService.setPIN(pin)
        securityStatus = securityService.status
    }

    func configureAppLock(_ settings: PlanAppLockSettings) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        try securityService.setAppLockSettings(settings)
        securityStatus = securityService.status
        if !settings.lockOnLaunch && !settings.lockOnForeground {
            setExternalPrivacyLocked(false)
        }
    }

    func unlockApp(withPIN pin: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        defer { securityStatus = securityService.status }
        try securityService.unlock(withPIN: pin)
        setExternalPrivacyLocked(false)
        scheduleWatchHealthRefresh()
    }

    func unlockAppWithBiometrics() async throws {
        guard let securityService else { throw PlanSecurityError.biometricUnavailable }
        try await securityService.unlockWithBiometrics()
        securityStatus = securityService.status
        setExternalPrivacyLocked(false)
        scheduleWatchHealthRefresh()
    }

    #if DEBUG
    @ObservationIgnored private var hasRunCurrentIslandVerification = false

    private func recordRequestedCurrentIslandVerification() {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--verify-current-island"),
              !hasRunCurrentIslandVerification, !isAppLocked,
              let reading = latestSensorReading else { return }
        let projection = currentLiveActivityProjection()
        let published = Activity<SensorCollectionActivityAttributes>.activities.first {
            $0.attributes.sessionID == sensorCollectionSessionID
        }?.content.state
        let action = TaptionLiveActivityCatPolicy.action(categoryID: projection.categoryID, title: projection.title)
        let bitmap = TaptionCatAtlasBitmap.image(style: settings.catStyle.rawValue, action: action, frame: published?.currentActivityFrame ?? 0)
        let report: [String: Any] = [
            "projectionCategoryID": projection.categoryID,
            "publishedCategoryID": published?.currentActivityCategoryID ?? "none",
            "publishedMatchesProjection": published?.currentActivityCategoryID == projection.categoryID,
            "latestMotion": reading.motion.rawValue,
            "motionConfidence": reading.motionConfidence.rawValue,
            "sampleAgeSeconds": Date.now.timeIntervalSince(reading.timestamp),
            "appBitmapAvailable": bitmap != nil,
            "bitmapWidth": bitmap?.size.width ?? 0,
            "bitmapHeight": bitmap?.size.height ?? 0,
            "frame": published?.currentActivityFrame ?? 0,
        ]
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaptionPlanIslandVerification", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("DYN1001B01-\(UUID().uuidString).json"), options: .atomic)
            hasRunCurrentIslandVerification = true
        } catch {
            Self.integrationLogger.error("Island verification metadata write failed")
        }
#endif
    }

    #endif

    // MARK: 백업 (월 단위 엔진)

    var backupDestinationAvailable: Bool { backupService != nil }

    func setLocalMonthsToKeep(_ months: Int) {
        guard let securityService else { return }
        securityService.setLocalMonthsToKeep(months)
        securityStatus = securityService.status
    }

    /// 백업·로컬 정리에 쓰는 비밀번호를 확인한다. 등록된 비밀번호와 같아야 하며 틀린 횟수가 세어진다.
    private func authorizeBackupPassword(_ password: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        defer { securityStatus = securityService.status }
        guard securityService.hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        try securityService.verifyPIN(password, unlocking: false)
    }

    /// iCloud Drive의 백업 파일 목록. 비밀번호를 넣기 전에는 월 이름과 파일 크기만 보이고,
    /// 행 수·마지막 시각은 비밀번호를 넣은 뒤(`password`)에만 채운다.
    func refreshBackupListings(password: String? = nil) async {
        guard let backupService else {
            backupListings = []
            return
        }
        do {
            backupListings = try await backupService.listings(password: password)
            backupListingError = nil
        } catch {
            backupListings = []
            backupListingError = PlanBackupPresenter.message(for: error)
        }
    }

    /// 저장소가 바뀐 뒤(복원·로컬 정리) 메모리 상태를 저장소에서 다시 만든다.
    /// repository의 known 캐시도 `load()`가 함께 갱신한다.
    private func reloadSnapshotAfterStoreChange() async throws {
        let loaded = try await repository.load()
        let prepared = try await Self.preparedLoadedSnapshotInBackground(loaded)
        snapshot = prepared
        selectedScale = TimeScale(timelineLevel: prepared.settings.startScale).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: prepared.settings.catStyle)
        liveMergeCacheKey = nil
        liveMergeCacheValue = []
        sensorRefreshFingerprints.removeAll()
        await dayLoadCoordinator?.invalidateAll()
        MapHomeDayCacheEviction.removeAll()
        backupRestoreRevision &+= 1
        publishWidgetPayload()
        publishWatchPayload()
    }

    private func beginBackupOperation(_ activity: PlanBackupActivity) -> Bool {
        guard !backupActivity.isBusy, acceptsDataMutation() else { return false }
        backupActivity = activity
        activeDataMutationCount += 1
        return true
    }

    /// 백업 중일 때만 진행 값을 바꾼다(끝난 뒤 늦게 도착한 알림은 무시).
    private func updateBackupProgress(completed: Int, total: Int) {
        guard case .backingUp = backupActivity else { return }
        let next = PlanBackupActivity.backingUp(completed: completed, total: max(total, 1))
        if backupActivity != next { backupActivity = next }
    }

    private func endBackupOperation(_ report: PlanBackupReport) {
        activeDataMutationCount -= 1
        backupActivity = .idle
        lastBackupReport = report
        securityStatus = securityService?.status ?? securityStatus
    }

    /// 진행 중 편집이 저장소에 반영된 뒤에 백업·복원이 시작되게 한다.
    private func flushPendingWrites() async {
        _ = await persist()
        _ = await repositoryWriteTask?.result
    }

    /// 지금 백업: 사용자가 입력한 비밀번호로 로컬 데이터가 있는 모든 달과 설정 파일을 iCloud Drive에 올린다.
    func backUpNow(password: String, now: Date = .now) async {
        guard beginBackupOperation(.backingUp(completed: 0, total: 1)) else {
            lastBackupReport = Self.backupBusyReport(.backup)
            return
        }
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation("icloud_backup_manual")
        var report: PlanBackupReport
        do {
            try authorizeBackupPassword(password)
            guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
            await flushPendingWrites()
            let results = try await backupService.backupAll(password: password, now: now) { [weak self] completed, total in
                Task { @MainActor in self?.updateBackupProgress(completed: completed, total: total) }
            }
            let items = results.map(PlanBackupPresenter.item(for:))
            if items.contains(where: { $0.kind == .done || $0.kind == .unchanged }) {
                securityService?.recordSuccessfulBackup(at: now)
            }
            let written = items.filter { $0.kind == .done }.count
            let rejected = items.filter { $0.kind == .rejected }.count
            report = PlanBackupReport(
                operation: .backup, finishedAt: now, items: items, failure: nil,
                summary: AppLanguagePreference.text(
                    korean: "백업 완료: 올림 \(written)개, 거부됨 \(rejected)개",
                    english: "Backup finished: \(written) uploaded, \(rejected) rejected"
                )
            )
            logger.finishOperation(operation, outcome: "success", fields: [
                "written": String(written), "rejected": String(rejected), "files": String(items.count),
            ])
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .backup, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "백업 실패: ", english: "Backup failed: ") + message
            )
            logger.finishOperation(operation, outcome: "failure", error: error)
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    /// 백업 후 로컬 정리: 끝난 달 중 백업을 다시 읽어 검증한 달만 이 기기에서 지운다.
    func offloadLocalMonths(password: String, now: Date = .now) async {
        guard beginBackupOperation(.offloading) else {
            lastBackupReport = Self.backupBusyReport(.offload)
            return
        }
        var report: PlanBackupReport
        do {
            try authorizeBackupPassword(password)
            guard let backupService, let securityService else {
                throw TaptionBackupError.destinationUnavailable("engine unavailable")
            }
            await flushPendingWrites()
            let results = try await backupService.offload(
                password: password, now: now, keepRecentMonths: securityService.localMonthsToKeep
            )
            let items = results.map(PlanBackupPresenter.item(for:))
            let sealed = items.filter { $0.kind == .done }.count
            if sealed > 0 { try await reloadSnapshotAfterStoreChange() }
            report = PlanBackupReport(
                operation: .offload, finishedAt: now, items: items, failure: nil,
                summary: AppLanguagePreference.text(
                    korean: "로컬 정리 완료: \(sealed)개 달을 정리, \(items.count - sealed)개 달은 건너뜀",
                    english: "Cleanup finished: \(sealed) months cleared, \(items.count - sealed) skipped"
                )
            )
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .offload, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "로컬 정리 실패: ", english: "Cleanup failed: ") + message
            )
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    /// 백업 한 개(월 또는 설정)를 비밀번호로 복원한다. 로컬에서 정리한 달을 다시 불러오는 데도 쓴다.
    /// 복원은 기존 로컬 행보다 새 것만 가져오고, 끝나면 repository를 다시 불러온다.
    func restoreBackup(_ scope: TaptionBackupScope, password: String, now: Date = .now) async {
        let name = PlanBackupPresenter.name(of: scope)
        guard beginBackupOperation(.restoring(name)) else {
            lastBackupReport = Self.backupBusyReport(.restore)
            return
        }
        var report: PlanBackupReport
        do {
            guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
            await flushPendingWrites()
            let summary = try await backupService.restore(scope, password: password)
            try await reloadSnapshotAfterStoreChange()
            let detail = AppLanguagePreference.text(
                korean: "센서 \(summary.newReadings)행 추가, 기록 \(summary.changedRecords)개 반영",
                english: "\(summary.newReadings) sensor rows added, \(summary.changedRecords) records applied"
            )
            report = PlanBackupReport(
                operation: .restore, finishedAt: now,
                items: [PlanBackupItem(name: name, kind: .done, detail: detail)], failure: nil,
                summary: AppLanguagePreference.text(korean: "\(name) 복원 완료", english: "Restored \(name)")
            )
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .restore, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "복원 실패: ", english: "Restore failed: ") + message
            )
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    private static func backupBusyReport(_ operation: PlanBackupReport.Operation) -> PlanBackupReport {
        let message = PlanSecurityError.backupInProgress.localizedDescription()
        return PlanBackupReport(operation: operation, finishedAt: .now, items: [], failure: message, summary: message)
    }

    /// iCloud 백업 파일을 모두 지운다. **되돌릴 수 없으므로 사용자 확인 뒤에만 부른다.**
    /// 실패한 파일이 있으면 이름을 담아 던진다. 성공하면 마지막 백업 시각도 지운다.
    func deleteAllBackupFiles(confirmed: Bool) async throws {
        guard confirmed else { throw CancellationError() }
        guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
        let result = try await backupService.deleteAllBackups()
        if !result.failed.isEmpty || !(result.remaining ?? []).isEmpty {
            throw BackupDeletionError(names: result.failed.map(\.name) + (result.remaining ?? []))
        }
        securityService?.clearLatestBackupDate()
        securityStatus = securityService?.status ?? securityStatus
        backupListings = []
    }

    private struct BackupDeletionError: LocalizedError {
        let names: [String]
        var errorDescription: String? { names.joined(separator: ", ") }
    }

    func setMapCategoryColor(_ hex: String, for categoryID: String) {
        if let categoryUUID = UUID(uuidString: categoryID),
           let index = snapshot.settings.mapUserActivityCategories.firstIndex(where: { $0.id == categoryUUID }) {
            guard snapshot.settings.mapUserActivityCategories[index].hex != hex else { return }
            snapshot.settings.mapUserActivityCategories[index].hex = hex
            Task { await persist() }
            return
        }
        var values = snapshot.settings.mapCategoryColors
        values[categoryID] = hex
        let normalized = AppFeatureSettings.normalizedMapCategoryColors(values)
        guard normalized != snapshot.settings.mapCategoryColors else { return }
        snapshot.settings.mapCategoryColors = normalized
        Task { await persist() }
    }

    @discardableResult
    func addMapUserActivityCategory(
        title: String,
        systemImage: String,
        hex: String
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        guard MapUserActivityIconCatalog.available(
            for: snapshot.settings.mapUserActivityCategories
        ).contains(systemImage) else {
            userFacingError = AppLanguagePreference.text(
                korean: "이미 사용 중인 행동분류 아이콘입니다.",
                english: "This activity category icon is already in use."
            )
            return false
        }
        let next = AppFeatureSettings.normalizedMapUserActivityCategories(
            snapshot.settings.mapUserActivityCategories + [
                MapUserActivityCategory(
                    id: UUID(),
                    title: title,
                    systemImage: systemImage,
                    hex: hex
                ),
            ]
        )
        guard next != snapshot.settings.mapUserActivityCategories else {
            return false
        }
        snapshot.settings.mapUserActivityCategories = next
        Task { await persist() }
        return true
    }

    func protectCurrentDataWithBiometrics() async throws {
        guard acceptsDataMutation() else { throw CancellationError() }
        guard let biometricProtectedSnapshotStore else {
            throw BiometricDataProtectionError.invalidArchive
        }
        biometricDataProtectionStatus = try await biometricProtectedSnapshotStore
            .protect(snapshot)
    }

    func validateBiometricProtectedData() async throws {
        guard let biometricProtectedSnapshotStore else {
            throw BiometricDataProtectionError.archiveMissing
        }
        biometricDataProtectionStatus = try await biometricProtectedSnapshotStore
            .validate()
    }

    func undoLastUserEdit() {
        guard let item = userEditUndoHistory.last else { return }
        guard let restored = item.entry.applying(to: snapshot, undo: true) else {
            userEditUndoHistory.removeLast()
            synchronizeUserEditHistoryAvailability()
            userFacingError = AppLanguagePreference.text(
                korean: "동기화된 변경과 충돌해 실행취소하지 못했습니다.",
                english: "Undo failed because it conflicts with synced changes."
            )
            return
        }
        guard restored != snapshot else { return }
        snapshot = restored
        userEditUndoHistory.removeLast()
        userEditRedoHistory.append(item)
        synchronizeUserEditHistoryAvailability()
        Task { await persist() }
    }

    func redoLastUserEdit() {
        guard let item = userEditRedoHistory.last else { return }
        guard let reapplied = item.entry.applying(to: snapshot, undo: false) else {
            userEditRedoHistory.removeLast()
            synchronizeUserEditHistoryAvailability()
            userFacingError = AppLanguagePreference.text(
                korean: "동기화된 변경과 충돌해 다시실행하지 못했습니다.",
                english: "Redo failed because it conflicts with synced changes."
            )
            return
        }
        guard reapplied != snapshot else { return }
        snapshot = reapplied
        userEditRedoHistory.removeLast()
        userEditUndoHistory.append(item)
        synchronizeUserEditHistoryAvailability()
        Task { await persist() }
    }

    private func recordUserEdit(
        from before: TaptionDataSnapshot,
        coalescingKey: String? = nil
    ) {
        let entry = AppModelHistoryEntry.difference(from: before, to: snapshot)
        guard !entry.isEmpty else { return }
        let now = Date.now
        if let coalescingKey,
           let previous = userEditUndoHistory.last,
           previous.coalescingKey == coalescingKey,
           now.timeIntervalSince(previous.recordedAt) <= 1.2 {
            userEditUndoHistory.removeLast()
            if let merged = previous.entry.mergingPlanChanges(with: entry) {
                userEditUndoHistory.append(
                    AppModelHistoryItem(
                        entry: merged,
                        coalescingKey: coalescingKey,
                        recordedAt: now
                    )
                )
            }
            userEditRedoHistory.removeAll()
            synchronizeUserEditHistoryAvailability()
            return
        }
        userEditUndoHistory.append(
            AppModelHistoryItem(
                entry: entry,
                coalescingKey: coalescingKey,
                recordedAt: now
            )
        )
        if userEditUndoHistory.count > 40 {
            userEditUndoHistory.removeFirst(
                userEditUndoHistory.count - 40
            )
        }
        userEditRedoHistory.removeAll()
        synchronizeUserEditHistoryAvailability()
    }

    private func clearUserEditRedoHistory() {
        guard !userEditRedoHistory.isEmpty else { return }
        userEditRedoHistory.removeAll()
        synchronizeUserEditHistoryAvailability()
    }

    private func synchronizeUserEditHistoryAvailability() {
        canUndo = !userEditUndoHistory.isEmpty
        canRedo = !userEditRedoHistory.isEmpty
    }

    /// 자동 기록의 원본은 보존하고, 시간표와 상세 화면에 표시할 활동만
    /// 사용자가 교정한다. 교정표는 기록 ID로 저장되어 다음 센서 갱신에도
    /// 같은 결과를 복원한다.
    func updateActualActivity(
        _ actualID: UUID,
        with option: ActivityCorrectionOption
    ) async {
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            return
        }
        let previous = snapshot
        let previousSpan = actual.endedAt.map {
            TimeSpan(start: actual.startedAt, end: $0)
        }
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion
        snapshot.settings.activityCorrections[actualID] =
            ActivityCorrectionEngine.replacingActivity(
                in: snapshot.settings.activityCorrections[actualID],
                with: option
            )
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep, let previousSpan {
            replaceConfirmedSleepSpans(removing: [previousSpan])
        }
        if option.categoryID == "sleep", let previousSpan {
            replaceConfirmedSleepSpans(adding: [previousSpan])
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        recordUserEdit(from: previous)
        await persist()
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": "record",
                "source": String(describing: actual.source),
            ]
        )
    }

    /// 자동 기록의 센서 원본은 그대로 두고, 화면에 표시할 시간만 조정한다.
    func updateActualSpan(
        _ actualID: UUID,
        startAt: Date,
        endAt: Date
    ) async {
        guard endAt > startAt,
              let actual = snapshot.actuals.first(where: { $0.id == actualID })
        else { return }
        let previous = snapshot
        let previousSpan = actual.endedAt.map {
            TimeSpan(start: actual.startedAt, end: $0)
        }
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion

        var correction = snapshot.settings.activityCorrections[actualID]
            ?? ActivityCorrection(
                title: actual.title,
                behavior: actual.behavior,
                categoryID: actual.categoryID
            )
        correction.startedAt = startAt
        correction.endedAt = endAt
        snapshot.settings.activityCorrections[actualID] = correction
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep, let previousSpan {
            replaceConfirmedSleepSpans(removing: [previousSpan])
        }
        if correction.categoryID == "sleep" {
            replaceConfirmedSleepSpans(
                adding: [TimeSpan(start: startAt, end: endAt)]
            )
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        recordUserEdit(from: previous)
        await persist()
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_span_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": "record",
                "source": String(describing: actual.source),
                "start": String(startAt.timeIntervalSince1970),
                "end": String(endAt.timeIntervalSince1970),
            ]
        )
    }

    /// 겹침 제거로 갈라진 표시 조각만 교정한다. 조각이 원본 전체와 같으면
    /// 기존 교정표를 쓰고, 일부면 자동 원본 위에 별도의 수동 기록을 얹는다.
    func correctActualFragment(
        _ actualID: UUID,
        displayedSpan: TimeSpan,
        startAt: Date,
        endAt: Date,
        with option: ActivityCorrectionOption?
    ) async {
        guard acceptsDataMutation() else { return }
        guard endAt > startAt,
              displayedSpan.duration > 0,
              let actual = snapshot.actuals.first(where: {
                  $0.id == actualID
              }) else {
            return
        }
        let previous = snapshot
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion

        if !ActivityFragmentCorrectionEngine.needsSeparateRecord(
            source: actual,
            displayedSpan: displayedSpan
        ) {
            var correction = snapshot.settings.activityCorrections[actualID]
                ?? ActivityCorrection(
                    title: actual.title,
                    behavior: actual.behavior,
                    categoryID: actual.categoryID
                )
            if let option {
                correction = ActivityCorrectionEngine.replacingActivity(
                    in: correction,
                    with: option
                )
            }
            correction.startedAt = startAt
            correction.endedAt = endAt
            snapshot.settings.activityCorrections[actualID] = correction
        } else {
            let fragmentID = ActivityFragmentCorrectionEngine.stableID(
                sourceID: actualID,
                span: displayedSpan
            )
            let createdAt = snapshot.actuals.first(where: {
                $0.id == fragmentID
            })?.createdAt ?? .now
            let fragment = ActivityFragmentCorrectionEngine.record(
                source: actual,
                displayedSpan: displayedSpan,
                correctedSpan: TimeSpan(start: startAt, end: endAt),
                option: option,
                createdAt: createdAt
            )
            if let index = snapshot.actuals.firstIndex(where: {
                $0.id == fragment.id
            }) {
                snapshot.actuals[index] = fragment
            } else {
                snapshot.actuals.append(fragment)
            }
        }

        if let option, option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep {
            replaceConfirmedSleepSpans(removing: [displayedSpan])
            if option == nil || option?.categoryID == "sleep" {
                replaceConfirmedSleepSpans(
                    adding: [TimeSpan(start: startAt, end: endAt)]
                )
            }
        } else if option?.categoryID == "sleep" {
            storeConfirmedSleepSpan(TimeSpan(start: startAt, end: endAt))
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        recordUserEdit(from: previous)
        await persist()
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": ActivityFragmentCorrectionEngine.needsSeparateRecord(
                    source: actual,
                    displayedSpan: displayedSpan
                ) ? "fragment" : "record",
                "source": String(describing: actual.source),
                "display_start": String(
                    displayedSpan.start.timeIntervalSince1970
                ),
                "display_end": String(
                    displayedSpan.end.timeIntervalSince1970
                ),
                "start": String(startAt.timeIntervalSince1970),
                "end": String(endAt.timeIntervalSince1970),
            ]
        )
    }

    /// 화면에서만 채워졌던 미확인 구간을 사용자가 결정한 파생 기록으로 남긴다.
    /// 센서·HealthKit 원본은 수정하거나 삭제하지 않는다.
    func classifyUnconfirmedSpan(
        _ span: TimeSpan,
        with option: ActivityCorrectionOption
    ) async {
        guard acceptsDataMutation() else { return }
        guard span.duration > 0 else { return }
        let alreadySaved = snapshot.actuals.contains { actual in
            actual.source == .manual
                && actual.manuallyCorrected
                && actual.title == option.title
                && actual.categoryID == option.categoryID
                && actual.behavior == option.behavior
                && actual.startedAt == span.start
                && actual.endedAt == span.end
        }
        guard !alreadySaved else { return }
        let previous = snapshot
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals.append(
            ActualRecord(
                planID: nil,
                title: option.title,
                categoryID: option.categoryID,
                startedAt: span.start,
                endedAt: span.end,
                source: .manual,
                confidence: .high,
                behavior: option.behavior,
                evidence: ["사용자가 미확인 구간을 분류함"],
                modelVersion: "manual-gap-classification-v1",
                manuallyCorrected: true
            )
        )
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        if option.categoryID == "sleep" {
            storeConfirmedSleepSpan(span)
        }
        recordUserEdit(from: previous)
        await persist()
    }

    func saveActivitySectionEdit(
        _ request: ActivitySectionEditRequest
    ) async -> ActivitySectionEditSaveResult? {
        guard acceptsDataMutation() else { return nil }
        let records = ActivitySectionOverrideEngine.records(for: request)
        guard !records.isEmpty else { return nil }
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_save_started",
            fields: [
                "source_count": String(request.sourceIDs.count),
                "piece_count": String(records.count),
                "start": String(request.originalSpan.start.timeIntervalSince1970),
                "end": String(request.originalSpan.end.timeIntervalSince1970),
            ]
        )

        let previous = snapshot
        let sourceIDs = Set(request.sourceIDs)
        let preservedPieces = snapshot.actuals
            .filter {
                sourceIDs.contains($0.id)
                    && ActivitySectionOverrideEngine.isEditableOverride($0)
            }
            .flatMap {
                ActivitySectionOverrideEngine.outsidePieces(
                    of: $0,
                    replacing: request.originalSpan
                )
            }
        snapshot.actuals.removeAll { actual in
            sourceIDs.contains(actual.id)
                && ActivitySectionOverrideEngine.isEditableOverride(actual)
        }
        snapshot.actuals.append(contentsOf: preservedPieces)
        snapshot.actuals.append(contentsOf: records)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        for option in editedOptions(in: request.mode) where option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        let editedSpan = primarySpan(for: request)
        if editedOptions(in: request.mode).contains(where: { $0.categoryID == "sleep" }) {
            replaceConfirmedSleepSpans(adding: [editedSpan])
        } else {
            replaceConfirmedSleepSpans(removing: [editedSpan])
        }

        let editRevision = snapshotRevision
        guard await persist() else {
            if snapshotRevision == editRevision { snapshot = previous }
            TaptionPlanDiagnosticsLogger.shared.record(
                "section_edit_save_failed",
                level: .error,
                fields: ["stage": "persist"]
            )
            return nil
        }

        do {
            let stored = try await repository.load()
            let storedIDs = Set(stored.actuals.map(\.id))
            let replacedByConfirmedSleep = records
                .filter { $0.categoryID == "sleep" }
            let expectedRecords = records.filter {
                !replacedByConfirmedSleep.contains($0)
            }
            guard (expectedRecords + preservedPieces).allSatisfy({ storedIDs.contains($0.id) }) else {
                userFacingError = AppLanguagePreference.text(
                    korean: "변경 내용을 저장소에서 다시 확인하지 못했습니다.",
                    english: "Changes could not be verified against storage again."
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "section_edit_save_failed",
                    level: .error,
                    fields: ["stage": "readback"]
                )
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "변경 내용을 저장소에서 다시 확인하지 못했습니다.",
                english: "Changes could not be verified against storage again."
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "section_edit_save_failed",
                level: .error,
                fields: [
                    "stage": "readback",
                    "error": String(describing: type(of: error)),
                ]
            )
            return nil
        }

        let selectedSpan = editedSpan
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_save_completed",
            fields: [
                "record_count": String(records.count),
                "selected_start": String(selectedSpan.start.timeIntervalSince1970),
                "selected_end": String(selectedSpan.end.timeIntervalSince1970),
            ]
        )
        recordUserEdit(from: previous)
        return ActivitySectionEditSaveResult(
            recordIDs: records.map(\.id),
            selectedSpan: selectedSpan
        )
    }

    private func editedOptions(
        in mode: ActivitySectionEditMode
    ) -> [ActivityCorrectionOption] {
        switch mode {
        case let .replace(_, option), let .cutLowerUnconfirmed(_, option),
             let .insertDetail(_, option):
            return [option]
        }
    }

    private func primarySpan(
        for request: ActivitySectionEditRequest
    ) -> TimeSpan {
        switch request.mode {
        case let .replace(editedSpan, _):
            return editedSpan.intersection(with: request.originalSpan)
                ?? request.originalSpan
        case let .cutLowerUnconfirmed(cutAt, _):
            return TimeSpan(start: request.originalSpan.start, end: cutAt)
        case let .insertDetail(detailSpan, _):
            return detailSpan.intersection(with: request.originalSpan)
                ?? request.originalSpan
        }
    }

    private func applyStoredActivityCorrections() {
        let confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: snapshot.settings.confirmedSleepSpans,
                corrections: snapshot.settings.activityCorrections,
                actuals: snapshot.actuals
            )
        if confirmedSleepSpans != snapshot.settings.confirmedSleepSpans {
            snapshot.settings.confirmedSleepSpans = confirmedSleepSpans
        }
        var corrected = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        corrected = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: corrected
        )
        guard corrected != snapshot.actuals else { return }
        snapshot.actuals = corrected
    }

    private func storeConfirmedSleepSpan(_ span: TimeSpan) {
        guard span.duration > 0 else { return }
        replaceConfirmedSleepSpans(adding: [span])
    }

    private func replaceConfirmedSleepSpans(
        removing: [TimeSpan] = [],
        adding: [TimeSpan] = []
    ) {
        snapshot.settings.confirmedSleepSpans =
            ConfirmedSleepSpanEditor.replacing(
                snapshot.settings.confirmedSleepSpans,
                removing: removing,
                adding: adding
            )
        snapshot.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: snapshot.actuals
        )
    }

    var currentAltitudeStatus: String? {
        guard let estimate = latestAltitudeEstimate else { return nil }
        let altitude = Int(estimate.seaLevelAltitudeMeters.rounded())
        let accuracy = Int(estimate.verticalAccuracyMeters.rounded())
        return AppLanguagePreference.text(
            korean: "\(estimate.floor)층 추정 · 해발 \(altitude)m · ±\(accuracy)m",
            english: "Estimated floor \(estimate.floor) · \(altitude) m above sea level · ±\(accuracy) m"
        )
    }

    var canShiftToPreviousPeriod: Bool {
        canShiftSelectedDate(by: -1)
    }

    var canShiftToNextPeriod: Bool {
        canShiftSelectedDate(by: 1)
    }

    var integrationStatusSummary: String {
        if isRefreshingIntegrations {
            return AppLanguagePreference.text(
                korean: "연동 확인 중",
                english: "Checking integrations"
            )
        }
        let enabled = [
            settings.showsPhotos
                && permissionState(for: .photos).isGranted,
            !settings.selectedCalendarIDs.isEmpty
                && permissionState(for: .calendar).isGranted,
            settings.healthEnabled,
            settings.locationEnabled,
        ].filter { $0 }.count
        return AppLanguagePreference.text(
            korean: enabled == 0
                ? "기기 안에 안전하게 저장"
                : "연동 \(enabled)개 사용 중",
            english: enabled == 0
                ? "Stored securely on this device"
                : "\(enabled) integrations in use"
        )
    }

    var healthIntegrationSummary: String {
        let deviceRecords = snapshot.actuals.filter {
            $0.source == .healthKit || $0.source == .appleWatch
        }
        let health = settings.healthEnabled
            ? AppLanguagePreference.text(
                korean: "원본 \(healthSyncOverview.totalSampleCount)건 · 일과 \(deviceRecords.count)건",
                english: "\(healthSyncOverview.totalSampleCount) source samples · \(deviceRecords.count) daily records"
            )
            : AppLanguagePreference.text(
                korean: "건강 연결 꺼짐",
                english: "Health connection off"
            )
        return "HealthKit · \(health)"
    }

    var healthSyncStatus: String {
        if let healthSyncProgress {
            return "\(healthSyncProgress.completedTypes)/\(healthSyncProgress.totalTypes)"
        }
        if healthSyncOverview.failedTypeCount > 0 {
            return AppLanguagePreference.text(
                korean: "완료 \(healthSyncOverview.completedTypeCount) · 오류 \(healthSyncOverview.failedTypeCount)",
                english: "Done \(healthSyncOverview.completedTypeCount) · Errors \(healthSyncOverview.failedTypeCount)"
            )
        }
        return AppLanguagePreference.text(
            korean: "\(healthSyncOverview.completedTypeCount)개 유형",
            english: "\(healthSyncOverview.completedTypeCount) types"
        )
    }

    var healthSyncDetail: String {
        if let healthSyncProgress {
            return AppLanguagePreference.text(
                korean: "\(healthSyncProgress.typeName) · \(healthSyncProgress.importedSamples)건 가져옴",
                english: "\(healthSyncProgress.typeName) · \(healthSyncProgress.importedSamples) imported"
            )
        }
        if let error = healthSyncOverview.lastError {
            return AppLanguagePreference.text(
                korean: "일부 건강 유형 재시도 필요 · \(error)",
                english: "Some Health types need a retry · \(error)"
            )
        }
        if let last = healthSyncOverview.lastSyncedAt {
            let lastText = last.formatted(date: .omitted, time: .shortened)
            return AppLanguagePreference.text(
                korean: "전체 이력·증분 원본 · 마지막 \(lastText)",
                english: "Full history · incremental source · last \(lastText)"
            )
        }
        return AppLanguagePreference.text(
            korean: "사용자가 허용한 전체 이력 · 기기 로컬 저장",
            english: "Full history you allowed · stored locally on this device"
        )
    }

    func selectTab(_ tab: RootTab) {
        if TaptionProductScope.automaticLoggingOnly, tab == .goals {
            selectedTab = .schedule
            detail = nil
            groupNavigationPath = []
            return
        }
        if tab == .review, reviewScale != .day {
            reviewScale = .day
        }
        selectedTab = tab
        detail = nil
        groupNavigationPath = []
        if tab == .schedule || tab == .review {
            // Selecting the same root tab is common while the timeline is
            // already visible. The integration gate below keeps that UI
            // action from rereading the same HealthKit/location window.
            Task { await refreshConnectedRecordsNow(force: false) }
        }
    }

    func openGroup(_ planID: UUID) {
        if groupNavigationPath.last != planID {
            if let current = groupNavigationPath.last,
               snapshot.plans.contains(where: {
                   $0.id == planID && $0.parentID == current
               }) {
                groupNavigationPath.append(planID)
            } else {
                groupNavigationPath = [planID]
            }
        }
        selectedGroupPlanID = planID
        detail = .group
    }

    func openGoalDetail(_ planID: UUID) {
        guard snapshot.plans.contains(where: { $0.id == planID }) else { return }
        selectedGoalPlanID = planID
        selectedGroupPlanID = nil
        groupNavigationPath = []
        detail = .goal
    }

    func closeGoalDetail() {
        selectedGoalPlanID = nil
        detail = nil
    }

    func closeCurrentGroup() {
        if groupNavigationPath.count > 1 {
            groupNavigationPath.removeLast()
            selectedGroupPlanID = groupNavigationPath.last
            detail = .group
        } else {
            groupNavigationPath = []
            selectedGroupPlanID = nil
            detail = nil
        }
    }

    func selectScale(_ scale: TimeScale) {
        let scheduleScale = scale.scheduleEquivalent
        guard selectedScale != scheduleScale else { return }
        selectedScale = scheduleScale
        scheduleCalendarStoreRefresh()
        if settings.rememberLastScale {
            snapshot.settings.startScale = scheduleScale.timelineLevel
        }
        // Only the visible EventKit window changes with scale. Sensor and
        // app-usage sources remain untouched.
        if settings.rememberLastScale {
            Task { await persist() }
        }
    }

    func shiftSelectedDate(by direction: Int) {
        guard canShiftSelectedDate(by: direction),
              let targetDate = TimelinePeriodNavigationEngine()
                .adjacentDate(
                    from: selectedDate,
                    level: selectedScale.timelineLevel,
                    direction: direction
                ) else {
            return
        }
        selectedDate = targetDate
    }

    /// 기록 탭은 시간표와 배율이 따로다. 원형 시간표를 옆으로 넘길 때는
    /// 기록 배율을 쓰되 데이터 경계는 시간표와 똑같이 지킨다.
    func shiftReviewDate(by direction: Int) {
        let navigation = TimelinePeriodNavigationEngine()
        let level = reviewScale.timelineLevel
        guard navigation.canNavigate(
            from: selectedDate,
            level: level,
            direction: direction,
            snapshot: snapshot
        ),
            let targetDate = navigation.adjacentDate(
                from: selectedDate,
                level: level,
                direction: direction
            ) else {
            return
        }
        selectedDate = targetDate
    }

    private func canShiftSelectedDate(by direction: Int) -> Bool {
        TimelinePeriodNavigationEngine().canNavigate(
            from: selectedDate,
            level: selectedScale.timelineLevel,
            direction: direction,
            snapshot: snapshot
        )
    }

    func returnToNow() {
        let wasToday = Calendar.autoupdatingCurrent.isDateInToday(selectedDate)
        selectedDate = .now
        if wasToday { scheduleSelectedDateRefresh() }
    }

    private func scheduleSelectedDateRefresh() {
        guard isSceneActive else { return }
        selectedDateRefreshGeneration &+= 1
        let generation = selectedDateRefreshGeneration
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.selectedDateRefreshGeneration == generation {
                    self.selectedDateRefreshTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
                while self.isRefreshingIntegrations {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                return
            }
            guard self.selectedDateRefreshGeneration == generation,
                  self.isSceneActive else { return }
            let selectedDate = self.selectedDate
            await self.refreshEnabledData(
                dataSpan: self.daySpan(containing: selectedDate),
                healthSpan: SleepAnalysisEngine.overnightSpan(
                    containing: selectedDate
                ),
                force: false
            )
        }
    }

    func openDeepLink(_ url: URL) async {
        guard let link = TaptionDeepLink(url: url) else { return }
        switch link {
        case .today:
            selectedTab = .schedule
            selectedScale = .day
            selectedDate = .now
            detail = nil
            return
        case .catPicker:
            selectedTab = .settings
            detail = .catPicker
            return
        case .plan(let planID):
            guard let plan = await planForDeepLink(planID) else {
                selectedTab = .schedule
                selectedScale = .day
                selectedDate = .now
                detail = nil
                selectedAction = nil
                publishWidgetPayload()
                return
            }

            selectedTab = .schedule
            selectedScale = .day
            selectedDate = plan.span.start
            detail = nil
            selectedAction = QuickActionItem(
                planID: plan.id,
                title: plan.title,
                time:
                    "\(plan.span.start.formatted(date: .omitted, time: .shortened)) → "
                    + plan.span.end.formatted(date: .omitted, time: .shortened),
                context: "계획 \(Int(plan.span.duration / 60))분"
            )
        }
    }

    private func planForDeepLink(_ planID: UUID) async -> PlanRecord? {
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        guard var loaded = try? await repository.load() else {
            return nil
        }
        guard let prepared = try? await Self.preparedLoadedSnapshotInBackground(
            loaded
        ) else { return nil }
        loaded = prepared
        snapshot = loaded
        publishWidgetPayload()
        return snapshot.plans.first { $0.id == planID }
    }

    nonisolated static func preparedLoadedSnapshot(
        _ source: TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows -> TaptionDataSnapshot {
        try cancellationCheck()
        var loaded = source
        loaded.plans = try Self.deduplicatedGeneratedRepeatPlans(
            loaded.plans,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        if loaded.categories.isEmpty {
            loaded.categories = CategoryCatalog.builtIn
        } else {
            for (index, category) in CategoryCatalog.builtIn.enumerated()
            where !loaded.categories.contains(where: {
                $0.id == category.id
            }) {
                if index.isMultiple(of: 32) { try cancellationCheck() }
                loaded.categories.append(category)
            }
        }
        try cancellationCheck()
        Self.migrateLegacyFloorCalibration(in: &loaded)
        try MemoShellPlanMigration.apply(
            to: &loaded,
            cancellationCheck: cancellationCheck
        )
        try Self.normalizeRecordRelationships(
            in: &loaded,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        loaded.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: loaded.actuals,
            suppressedIDs: loaded.settings.suppressedActualIDs
        )
        try cancellationCheck()
        loaded.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: loaded.settings.confirmedSleepSpans,
                corrections: loaded.settings.activityCorrections,
                actuals: loaded.actuals
            )
        try cancellationCheck()
        loaded.actuals = ActivityCorrectionEngine.applying(
            loaded.settings.activityCorrections,
            to: loaded.actuals
        )
        try cancellationCheck()
        loaded.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            loaded.settings.confirmedSleepSpans,
            to: loaded.actuals
        )
        try cancellationCheck()
        loaded.weather = WeatherTimelineEngine.coalesced(loaded.weather)
        try cancellationCheck()
        return loaded
    }

    private nonisolated static func preparedLoadedSnapshotInBackground(
        _ source: TaptionDataSnapshot,
        lockingAutomaticClassifications: Bool = false,
        priority: TaskPriority? = .utility
    ) async throws -> TaptionDataSnapshot {
        let worker = Task.detached(priority: priority) {
            var loaded = source
            if lockingAutomaticClassifications {
                loaded.actuals = try ActivityClassificationLockEngine
                    .lockingAutomaticClassifications(
                        loaded.actuals,
                        cancellationCheck: { try Task.checkCancellation() }
                    )
                var travel: [TravelSegment] = []
                travel.reserveCapacity(loaded.travel.count)
                for (index, segment) in loaded.travel.enumerated() {
                    if index.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    var value = segment
                    value.isClassificationLocked = true
                    travel.append(value)
                }
                loaded.travel = travel
            }
            loaded = try preparedLoadedSnapshot(
                loaded,
                cancellationCheck: { try Task.checkCancellation() }
            )
            loaded.actuals = try PlanActualStorage.reusingUnchangedStorage(loaded.actuals,
                previous: source.actuals, cancellationCheck: { try Task.checkCancellation() })
            return loaded
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    /// A repeat rule is materialized as one child plan per matching day. If
    /// an older build saved the same generated child twice, keep the first
    /// record and remove only the exact generated duplicate. User-created
    /// overlapping plans remain untouched and continue to be shown separately.
    private nonisolated static func deduplicatedGeneratedRepeatPlans(
        _ plans: [PlanRecord],
        cancellationCheck: () throws -> Void
    ) rethrows -> [PlanRecord] {
        try cancellationCheck()
        var seen = Set<String>()
        var deduplicated: [PlanRecord] = []
        deduplicated.reserveCapacity(plans.count)
        for (index, plan) in plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard plan.origin == .repeatRule else {
                deduplicated.append(plan)
                continue
            }
            let key = [
                plan.parentID?.uuidString ?? "-",
                plan.categoryID,
                String(Int(plan.span.start.timeIntervalSinceReferenceDate.rounded())),
                String(Int(plan.span.end.timeIntervalSinceReferenceDate.rounded())),
            ].joined(separator: "|")
            if seen.insert(key).inserted { deduplicated.append(plan) }
        }
        try cancellationCheck()
        return deduplicated
    }

    /// Converts legacy action/routine pointers into the canonical relation
    /// rules used by the timeline graph. Repeat segments are projections of a
    /// root routine and therefore never remain as direct automatic links.
    private nonisolated static func normalizeRecordRelationships(
        in snapshot: inout TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        var plansByID: [UUID: PlanRecord] = [:]
        plansByID.reserveCapacity(snapshot.plans.count)
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if plansByID[plan.id] == nil { plansByID[plan.id] = plan }
        }

        func rootRoutineID(for id: UUID) throws -> UUID? {
            var currentID: UUID? = id
            var visited = Set<UUID>()
            var depth = 0
            while let current = currentID,
                  visited.insert(current).inserted,
                  let plan = plansByID[current] {
                if depth.isMultiple(of: 64) { try cancellationCheck() }
                if GoalRecordPolicy.isGoal(plan) { return plan.id }
                currentID = plan.parentID
                depth += 1
            }
            return nil
        }

        for index in snapshot.actuals.indices {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            var actual = snapshot.actuals[index]
            let linkedPlan = actual.planID.flatMap { plansByID[$0] }
            let linkedRoutine = try actual.routineID.map(rootRoutineID) ?? nil
            let resolvedRoutine: UUID?
            if let linkedRoutine {
                resolvedRoutine = linkedRoutine
            } else if let linkedPlan {
                resolvedRoutine = try rootRoutineID(for: linkedPlan.id)
            } else {
                resolvedRoutine = nil
            }
            if AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual) {
                actual.routineID = resolvedRoutine
                actual.planID = nil
            } else if let linkedPlan {
                if linkedPlan.origin == .repeatRule
                    || GoalRecordPolicy.isGoal(linkedPlan) {
                    actual.routineID = resolvedRoutine
                    actual.planID = nil
                } else {
                    actual.planID = linkedPlan.id
                    actual.routineID = resolvedRoutine
                }
            } else {
                actual.planID = nil
                actual.routineID = linkedRoutine
            }
            snapshot.actuals[index] = actual
        }

        func canonicalNodeID(_ raw: String) throws -> String? {
            let prefixes = ["routine.", "action."]
            guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else {
                return raw.hasPrefix("automatic.") ? raw : nil
            }
            guard let id = UUID(uuidString: String(raw.dropFirst(prefix.count))),
                  let plan = plansByID[id] else {
                return nil
            }
            if GoalRecordPolicy.isGoal(plan) || plan.origin == .repeatRule,
               let root = try rootRoutineID(for: plan.id) {
                return "routine.\(root.uuidString)"
            }
            return "action.\(id.uuidString)"
        }

        let orderedLinks = try RouteTimelineCancellableSort.sorted(
            snapshot.recordLinks,
            by: { $0.createdAt < $1.createdAt },
            cancellationCheck: cancellationCheck
        )
        var seen = Set<String>()
        var normalizedLinks: [RecordLink] = []
        normalizedLinks.reserveCapacity(orderedLinks.count)
        for (index, link) in orderedLinks.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let from = try canonicalNodeID(link.fromNodeID),
                  let to = try canonicalNodeID(link.toNodeID),
                  from != to else { continue }
            let key = "\(from)->\(to)"
            guard seen.insert(key).inserted else { continue }
            var normalized = link
            normalized.fromNodeID = from
            normalized.toNodeID = to
            normalizedLinks.append(normalized)
        }
        try cancellationCheck()
        snapshot.recordLinks = normalizedLinks
    }

    func bootstrap() async {
        await bootstrapLocalSnapshot()
        scheduleBootstrapPreparation()
        await waitForBootstrapPreparation()
    }

    func prepareLocalDataForDisplay() async {
        await bootstrapLocalSnapshot()
    }

    private func prepareStartupSettings() async {
        guard !isBootstrapped, !hasPreparedStartupSettings,
              allowsRepositoryLoadAttempt() else { return }
        if let startupSettingsTask { await startupSettingsTask.value; return }
        let generation = dataDeletionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startupSettingsTask = nil }
            do {
                guard let source = try await repository.loadStartupSnapshot() else { return }
                try Task.checkCancellation()
                guard generation == dataDeletionGeneration,
                      !isBootstrapped, allowsRepositoryLoadAttempt() else { return }
                snapshot = source
                selectedScale = TimeScale(timelineLevel: source.settings.startScale).scheduleEquivalent
                selectedCatCoat = CatCoat(catStyle: source.settings.catStyle)
                isStartupSnapshotPartial = true
                hasPreparedStartupSettings = true
                TaptionPlanDiagnosticsLogger.shared.record("startup_settings_ready")
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record("startup_settings_deferred",
                    fields: ["error": String(describing: type(of: error))])
            }
        }
        startupSettingsTask = task
        await task.value
    }

    private func bootstrapLocalSnapshot() async {
        guard allowsRepositoryLoadAttempt() else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let isRecoveringFromLoadFailure = repositoryLoadFailed
        guard !isBootstrapped || isRecoveringFromLoadFailure else { return }

        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation("bootstrap_local_snapshot")
        logger.record("bootstrap_started")
        let task = Task { [weak self] in
            guard let self else { return }
            let generation = dataDeletionGeneration
            defer {
                if generation == dataDeletionGeneration { bootstrapTask = nil }
            }
            do {
                let source = try await repository.load()
                try Task.checkCancellation()
                guard generation == dataDeletionGeneration,
                      allowsRepositoryLoadAttempt() else { return }
                repositoryLoadFailed = false
                if isRecoveringFromLoadFailure,
                   AppModelMessage.isDataLoadFailure(userFacingError) {
                    userFacingError = nil
                }
                // Publish local data before normalization, sensors or cloud work.
                isStartupSnapshotPartial = false
                snapshot = source
                selectedScale = TimeScale(
                    timelineLevel: source.settings.startScale
                ).scheduleEquivalent
                selectedCatCoat = CatCoat(catStyle: source.settings.catStyle)
                needsBootstrapPreparation = true
                isBootstrapped = true
                if hasPreparedStartupSettings && isSceneActive {
                    updateForegroundLiveLocationTracking()
                    scheduleWatchHealthRefresh()
                }
                logger.record(
                    "bootstrap_local_snapshot_loaded",
                    fields: [
                        "plans": String(source.plans.count),
                        "actuals": String(source.actuals.count),
                        "places": String(source.places.count),
                    ]
                )
                logger.finishOperation(operation, outcome: "success")
                scheduleBootstrapPreparation()
            } catch is CancellationError {
                logger.finishOperation(operation, outcome: "cancelled")
                return
            } catch {
                guard allowsRepositoryLoadAttempt() else { return }
                isStartupSnapshotPartial = false
                hasPreparedStartupSettings = false
                if !isRecoveringFromLoadFailure {
                    var fallback = TaptionDataSnapshot.empty
                    fallback.categories = CategoryCatalog.builtIn
                    snapshot = fallback
                }
                repositoryLoadFailed = true
                needsBootstrapPreparation = false
                isBootstrapped = true
                userFacingError = AppModelMessage
                    .dataLoadFailed(error.localizedDescription).text()
                logger.finishOperation(operation, outcome: "failure", error: error)
                logger.record(
                    "bootstrap_failed",
                    level: .error,
                    fields: ["error": String(describing: type(of: error))]
                )
            }
        }
        bootstrapTask = task
        await task.value
    }

    private func scheduleBootstrapPreparation() {
        guard needsBootstrapPreparation,
              acceptsDataMutation(), bootstrapPreparationTask == nil else {
            return
        }
        bootstrapPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let generation = dataDeletionGeneration
            let logger = TaptionPlanDiagnosticsLogger.shared
            let operation = logger.beginOperation("bootstrap_preparation")
            var outcome = "cancelled"
            defer {
                if generation == dataDeletionGeneration {
                    bootstrapPreparationTask = nil
                }
                logger.finishOperation(operation, outcome: outcome)
            }
            // Let the initial scene continue before preparing the full record graph.
            await Task.yield()
            guard !Task.isCancelled, self.acceptsDataMutation() else {
                return
            }
            var source = snapshot
            let originalConfirmedSleepSpans = source.settings.confirmedSleepSpans
            let originalActuals = source.actuals
            let originalTravel = source.travel
            do {
                while true {
                    let revision = snapshotRevision
                    source = try await Self.preparedLoadedSnapshotInBackground(
                        source,
                        lockingAutomaticClassifications: true
                    )
                    guard !Task.isCancelled,
                          generation == dataDeletionGeneration,
                          acceptsDataMutation() else { return }
                    if revision == snapshotRevision { break }
                    source = snapshot
                }
            } catch {
                return
            }
            snapshot = source
            needsLocalRecordNormalization = false
            if source.settings.confirmedSleepSpans != originalConfirmedSleepSpans
                || source.actuals != originalActuals
                || source.travel != originalTravel {
                _ = await persist()
            }
            guard !Task.isCancelled,
                  generation == dataDeletionGeneration,
                  acceptsDataMutation() else { return }
            needsBootstrapPreparation = false
            if source.updatedAt == .distantPast, source.plans.isEmpty {
                openInitialSetup()
            }
            publishWatchPayload()
            await applyPendingWidgetCommands(repositoryAlreadyLoaded: true)
            outcome = "success"
        }
    }

    private func waitForBootstrapPreparation() async {
        await bootstrapPreparationTask?.value
    }

    func sceneBecameActive() async {
        SensorBackgroundWakeNotification.cancel()
        isCommerceLocked = false
        let wasSceneActive = isSceneActive
        isSceneActive = true
        if let securityService {
            if !isBootstrapped {
                securityService.handleLaunch()
            } else if !wasSceneActive {
                securityService.handleForeground()
            }
            securityStatus = securityService.status
            if isAppLocked {
                TaptionExternalPrivacyStore.setLocked(true)
            }
        }
        await prepareStartupSettings()
        if hasPreparedStartupSettings && !isBootstrapped {
            Task { @MainActor [weak self] in await self?.bootstrapLocalSnapshot() }
        } else {
            await bootstrapLocalSnapshot()
        }
        updateForegroundLiveLocationTracking()
        if isAppLocked {
            await concealExternalSurfaces()
        } else {
            setExternalPrivacyLocked(false)
        }
        guard !wasSceneActive else { return }
        if !pendingSensorAnalysisRevisions.isEmpty {
            startSensorAnalysis(immediately: false)
        }
        scheduleWatchHealthRefresh()
        scheduleForegroundPreparation()
        if postSaveRefreshRequested { schedulePostSaveRefresh() }
    }

    func handleMemoryPressure() {
        TaptionPlanDiagnosticsLogger.shared.record("application_memory_warning", level: .notice)
        dayLoadCoordinator?.handleMemoryPressure()
        MapHomeDayCacheEviction.removeAll()
        let repository = self.repository
        Task { await repository.handleMemoryPressure() }
    }

    private func scheduleForegroundPreparation() {
        foregroundPreparationTask?.cancel()
        foregroundPreparationGeneration &+= 1
        let generation = foregroundPreparationGeneration
        foregroundPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundPreparationGeneration == generation {
                    self.foregroundPreparationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  self.isSceneActive,
                  self.foregroundPreparationGeneration == generation else {
                return
            }

            await self.refreshPermissions()
            guard !Task.isCancelled,
                  self.isSceneActive,
                  self.foregroundPreparationGeneration == generation else {
                return
            }
            self.updateForegroundLiveLocationTracking()

            await self.applyPendingLocationTrackingRequest()
            await self.hydrateLatestMapLocationAnchor()
            self.applyPendingLocationTrackingGuidance()
            self.airPodsActivityService.start { [weak self] observation in
                self?.applyAirPodsActivity(observation)
            }
            self.scheduleForegroundRefresh()
        }
    }

    private func applyPendingLocationTrackingRequest() async {
        guard let enabled = TaptionLocationTrackingRequestStore.take() else {
            return
        }
        if enabled {
            await enableLocationCollection()
        } else {
            await disableLocationCollection()
        }
    }

    private func applyPendingLocationTrackingGuidance() {
        guard TaptionLocationTrackingRequestStore.takeGuidanceRequest() else {
            return
        }
        presentPermissionOnboarding(for: .location)
    }

    private func hydrateLatestMapLocationAnchor() async {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: .now)
        guard latestMapAnchorHydratedDay != dayStart else { return }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
        guard let readings = try? await sensorService.archivedReadings(in: span) else {
            return
        }
        latestMapAnchorHydratedDay = dayStart
        guard let latest = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
        ) else { return }
        if latestSensorReading != latest {
            latestSensorReading = latest
        }
    }

    func sceneEnteredBackground() async {
        // Checkpoint, final persist and backup below need more time than iOS
        // gives a suspending scene, so hold an assertion until they finish.
        let backgroundAssertion = BackgroundTaskAssertion()
        backgroundAssertion.begin(name: "TaptionPlan.sceneBackground") {}
        defer { backgroundAssertion.end() }
        isSceneActive = false
        updateForegroundLiveLocationTracking()
        let cancelledSensorTimeline = sensorTimelineTask
        sensorTimelineTask?.cancel()
        cancelSensorAnalysisUntilForeground()
        postSaveRefreshTask?.cancel()
        if postSaveRefreshTask != nil { postSaveRefreshRequested = true }
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = nil
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        dayLoadCoordinator?.prepareForBackground()
        foregroundPreparationGeneration &+= 1
        foregroundPreparationTask?.cancel()
        foregroundPreparationTask = nil
        if securityStatus.settings.lockOnLaunch
            || securityStatus.settings.lockOnForeground {
            await concealExternalSurfaces()
        }
        for observation in airPodsActivityService.stop(at: .now) {
            applyAirPodsActivity(observation)
        }
        await resumeSensorCollectionAndRestoreTrackingIfNeeded()
        await scheduleSensorWakeNotificationIfNeeded()
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask?.cancel()
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        liveWeatherRefreshTask?.cancel()
        if let rawDeviceDataArchive {
            try? await rawDeviceDataArchive.checkpoint()
        }
        // A refresh that is still unwinding makes the persist below defer to
        // a trailing write, which may never run once the app is suspended.
        _ = await cancelledSensorTimeline?.value
        await persistDeviceLocalSnapshot(force: true)
        await repository.handleMemoryPressure()
    }

    func suspendForCommerceLock() async {
        isCommerceLocked = true
        isSceneActive = false
        cancelSensorAnalysisUntilForeground()
        await concealExternalSurfaces()
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = nil
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        foregroundPreparationGeneration &+= 1
        foregroundPreparationTask?.cancel()
        foregroundPreparationTask = nil
        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        SensorBackgroundWakeNotification.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask?.cancel()
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        liveWeatherRefreshTask?.cancel()
        if activeTrackingSession != nil {
            await stopTracking()
        }
    }

    private func applyAirPodsActivity(
        _ observation: AirPodsActivityObservation
    ) {
        guard acceptsDataMutation(
            capturedAt: observation.endedAt ?? observation.startedAt
        ),
        !snapshot.settings.suppressedActualIDs.contains(observation.id)
        else { return }
        let source: ActualSource
        let behavior: String
        switch observation.kind {
        case .music:
            source = .media
            behavior = "music"
        case .call:
            source = .call
            behavior = "call"
        }
        let actual = ActualRecord(
            id: observation.id,
            planID: nil,
            routineID: nil,
            title: observation.title,
            categoryID: "activity",
            startedAt: observation.startedAt,
            endedAt: observation.endedAt,
            source: source,
            confidence: .high,
            createdAt: observation.startedAt,
            behavior: behavior,
            evidence: ["AirPods · (observation.routeName)"],
            modelVersion: "airpods-observer-v1"
        )
        if let index = snapshot.actuals.firstIndex(where: {
            $0.id == observation.id
        }) {
            guard snapshot.actuals[index] != actual else { return }
            snapshot.actuals[index] = actual
        } else {
            snapshot.actuals.append(actual)
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        Task { await persistDeviceLocalSnapshot() }
    }

    /// 알람 확인으로 실제 기록을 남긴다. 시작(출근·등교·기상)은 열린 기록을 만들고, 끝(퇴근·하교)은 같은 종류의 열린 기록을 닫는다.
    func confirmAlarmRecord(categoryID: String, title: String, at date: Date, opens: Bool) {
        guard acceptsDataMutation() else { return }
        if opens {
            snapshot.actuals.append(ActualRecord(
                id: UUID(),
                planID: nil,
                routineID: nil,
                title: title,
                categoryID: categoryID,
                startedAt: date,
                endedAt: nil,
                source: .manual,
                confidence: .high,
                createdAt: .now,
                behavior: nil,
                evidence: ["알람 확인"],
                modelVersion: nil
            ))
        } else if let index = snapshot.actuals.indices
            .filter({ snapshot.actuals[$0].categoryID == categoryID && snapshot.actuals[$0].endedAt == nil })
            .max(by: { snapshot.actuals[$0].startedAt < snapshot.actuals[$1].startedAt }),
                  date >= snapshot.actuals[index].startedAt {
            snapshot.actuals[index].endedAt = date
            snapshot.actuals[index].manuallyCorrected = true
        } else {
            return
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        Task { await persistDeviceLocalSnapshot() }
    }

    private func scheduleForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Two yields leave room for SwiftUI to commit the loaded snapshot
            // and present the first timeline before integrations enumerate
            // Photos, Calendar and HealthKit.
            await Task.yield()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.isSceneActive else {
                self.foregroundRefreshTask = nil
                return
            }
            if let lastForegroundRefreshAt = self.lastForegroundRefreshAt,
               Date.now.timeIntervalSince(lastForegroundRefreshAt) < 5 {
                self.foregroundRefreshTask = nil
                return
            }
            self.watchConnectivityService.refreshConnectionState()
            self.refreshWatchLaunchReport()
            await self.configureHealthBackgroundDeliveryIfNeeded(
                showErrors: false
            )
            self.startForegroundHealthRefreshIfNeeded()
            await self.refreshPermissionStates()
            await self.waitForBootstrapPreparation()
            await self.applyPendingWidgetCommands(
                repositoryAlreadyLoaded: false
            )
            await self.resumeSensorCollectionAndRestoreTrackingIfNeeded()
            await self.refreshEnabledData(
                includesCurrentDeviceDay: true,
                dataSpan: self.currentDeviceDataSpan,
                healthSpan: self.startupHealthSpan,
                includesHealth: false
            )
            self.lastForegroundRefreshAt = .now
            self.foregroundRefreshTask = nil
            self.scheduleDeferredVisibleRefresh()
            self.scheduleCalendarStoreRefresh()
        }
    }

    private func scheduleDeferredVisibleRefresh() {
        guard deferredVisibleRefreshTask == nil else { return }
        deferredVisibleRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, self.isSceneActive else {
                self.deferredVisibleRefreshTask = nil
                return
            }
            await self.synchronizeCloud(showErrors: false)
            await self.persistDeviceLocalSnapshot()
            self.deferredVisibleRefreshTask = nil
        }
    }

    /// Refreshes device-backed records and republishes the shared widget
    /// payload when iOS wakes the app without presenting its UI.
    func performBackgroundRefresh(
        wakeReason: SensorWakeReason = .bgAppRefresh
    ) async -> Bool {
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation(
            "background_refresh",
            fields: ["wake_reason": wakeReason.rawValue]
        )
        defer {
            let outcome: String
            if Task.isCancelled {
                outcome = "cancelled"
            } else {
                outcome = userFacingError == nil ? "success" : "failure"
            }
            logger.finishOperation(
                operation,
                outcome: outcome,
                fields: [
                    "wake_reason": wakeReason.rawValue,
                    "sensor_collecting": String(isSensorCollecting),
                ]
            )
        }
        Self.integrationLogger.notice("Background model refresh started")
        receiveSensorWake(wakeReason)
        await bootstrap()
        await waitForBootstrapPreparation()
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        await refreshPermissionStates()
        let samplingWindow = settings.sensorCollectionProfile.samplingWindowDuration
        let sensorService = self.sensorService
        let persistenceToken = sensorService?.persistenceToken() ?? 0
        await self.resumeSensorCollectionAndRestoreTrackingIfNeeded()
        if isSensorCollecting, let sensorService {
            sensorService.requestImmediateSample()
            // BG refresh tasks may be terminated as soon as this method
            // returns. Wait for the archive consumer to confirm one write,
            // rather than assuming the sampling window completed it.
            let didPersist = await sensorService.waitForPersistedReading(
                after: persistenceToken,
                timeout: samplingWindow + 2
            )
            if didPersist {
                let savedToken = sensorService.persistenceToken()
                _ = sensorBackgroundCoordinator.markSaved(
                    persistedToken: savedToken
                )
                syncSensorBackgroundState()
            } else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_background_sample_not_persisted",
                    level: .notice,
                    fields: [
                        "stream_live": String(
                            sensorService.isCollectionLive()
                        ),
                        "archive_error": sensorService
                            .lastPersistenceErrorDescription ?? "none",
                    ]
                )
                if !sensorService.isCollectionLive() {
                    isSensorCollecting = false
                    sensorBackgroundCoordinator.endSession()
                    syncSensorBackgroundState()
                }
            }
        }
        await refreshEnabledData(
            includesCurrentDeviceDay: true,
            persistDeviceSnapshot: false
        )
        await persist()
        await reconcileSensorCollectionLiveActivity(isForeground: false)
        await scheduleSensorWakeNotificationIfNeeded()
        let success = userFacingError == nil
        Self.integrationLogger.notice(
            "Background model refresh finished: success=\(success, privacy: .public), snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public)"
        )
        return success
    }

    func performHealthBackgroundRefresh() async {
        await handleObservedHealthChange()
        await reconcileSensorCollectionLiveActivity(isForeground: false)
    }

    func reconcileSensorCollectionLiveActivity(
        isForeground: Bool
    ) async {
        let controller = SensorCollectionLiveActivityController.shared
        let kinds = sensorCollectionKinds
        let projection = currentLiveActivityProjection()
        await liveActivityController.updateCompactActivity(
            title: projection.title,
            categoryID: projection.categoryID,
            animationFrame: sensorSaveToken % 6
        )
        guard sensorCollectionSessionState == .collecting,
              let sessionID = sensorCollectionSessionID,
              let startedAt = sensorCollectionStartedAt else {
            await controller.removeExpired()
            await controller.stop(
                lastSavedAt: lastSensorSavedAt,
                collectionKinds: kinds,
                saveToken: sensorSaveToken
            )
            return
        }
        _ = try? await controller.reconcile(
            sessionID: sessionID,
            startedAt: startedAt,
            lastSavedAt: lastSensorSavedAt,
            collectionKinds: kinds,
            isCollecting: true,
            isForeground: isForeground,
            intervalSeconds: settings.gpsLoggingPreferences
                .effectiveIntervalSeconds,
            saveToken: sensorSaveToken,
            validSampleKinds: latestSensorReading.map {
                validSensorCollectionKinds(for: $0)
            } ?? [],
            isExternalSample: latestSensorReading?.sourceDevice == .appleWatch,
            latestHeartRate: latestHeartRate,
            heartRateUpdatedAt: latestHeartRateUpdatedAt,
            currentActivityTitle: projection.title,
            currentActivityCategoryID: projection.categoryID,
            currentActivitySystemImage: projection.systemImage,
            currentActivityCatStyle: settings.catStyle.rawValue
        )
        #if DEBUG
        recordRequestedCurrentIslandVerification()
        #endif
    }

    private var sensorCollectionKinds: [String] {
        var kinds = ["location"]
        if let availability = sensorAvailability {
            if availability.motionActivity || availability.deviceMotion {
                kinds.append("motion")
            }
            if availability.relativeAltitude {
                kinds.append("altitude")
            }
            if availability.stepCounting {
                kinds.append("steps")
            }
        }
        if settings.healthEnabled {
            kinds.append("health")
        }
        kinds.append("wifi")
        return kinds
    }

    private func validSensorCollectionKinds(
        for reading: SensorReading
    ) -> [String] {
        var kinds: [String] = []
        if reading.gpsAvailable,
           let point = reading.point,
           (-90...90).contains(point.latitude),
           (-180...180).contains(point.longitude),
           point.horizontalAccuracy.isFinite,
           point.horizontalAccuracy >= 0,
           point.horizontalAccuracy <= 150 {
            kinds.append("location")
        }
        if reading.motion != .unknown
            || reading.deviceMotion != nil
            || reading.deviceMotionSummary != nil {
            kinds.append("motion")
        }
        if reading.relativeAltitudeMeters?.isFinite == true
            || reading.pressureKilopascals?.isFinite == true {
            kinds.append("altitude")
        }
        let hasValidStepCount = reading.stepCount.map { $0 >= 0 } ?? false
        let hasValidWalkingDistance = reading.walkingRunningDistanceMeters.map {
            $0.isFinite && $0 >= 0
        } ?? false
        let hasValidCadence = reading.currentCadenceStepsPerSecond.map {
            $0.isFinite && $0 >= 0
        } ?? false
        if hasValidStepCount || hasValidWalkingDistance || hasValidCadence {
            kinds.append("steps")
        }
        if settings.healthEnabled,
           reading.sourceDevice == .appleWatch {
            kinds.append("health")
        }
        if let ssid = reading.connectedWiFiSSID,
           !ssid.isEmpty {
            kinds.append("wifi")
        }
        return kinds
    }

    private func scheduleSensorWakeNotificationIfNeeded() async {
        guard settings.notificationsEnabled,
              permissionState(for: .notifications).isGranted,
              sensorCollectionSessionState == .collecting else {
            SensorBackgroundWakeNotification.cancel()
            return
        }
        await SensorBackgroundWakeNotification.schedule(
            after: SensorBackgroundRefreshPolicy.savedDelay()
        )
    }

    func permissionState(for feature: PermissionFeature) -> PermissionState {
        snapshot.settings.permissions[feature] ?? .notDetermined
    }

    func requiredPermissionGate(
        liveActivitiesEnabled: Bool
    ) -> RequiredPermissionGate {
        // 위치·동작은 저장된 캐시가 아니라 지금 시스템 상태를 읽는다. 설정 앱에서
        // 허용하고 돌아온 직후에도 카드가 남지 않게 하기 위해서다.
        var permissions = snapshot.settings.permissions
        if let sensorService {
            permissions[.location] = sensorService.locationPermissionState()
            permissions[.motion] = sensorService.motionPermissionState()
        }
        return RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: permissions,
                locationAlwaysAuthorized:
                    sensorService?.hasAlwaysLocationAuthorization() == true,
                locationPrecise:
                    sensorService?.hasPreciseLocationAuthorization() == true,
                healthKitRequestCompleted: UserDefaults.standard.bool(
                    forKey: Self.healthAuthorizationRequestedKey
                ),
                liveActivitiesEnabled: liveActivitiesEnabled
            )
        )
    }

    func requestRequiredPermission(
        _ permission: RequiredPermission
    ) async {
        switch permission {
        case .locationAlways:
            if sensorService?.locationPermissionState() == .denied {
                openSystemSettings()
            } else {
                await enableLocationCollection(always: true, opensSettingsWhenBlocked: true)
            }
        case .locationPrecise:
            if sensorService?.hasPreciseLocationAuthorization() != true {
                openSystemSettings()
            }
        case .motion:
            guard let sensorService else { return }
            if sensorService.motionPermissionState() == .denied {
                openSystemSettings()
            } else {
                snapshot.settings.permissions[.motion] =
                    await sensorService.requestMotionPermission()
                await persist()
            }
        case .healthKitRequestCompleted:
            await requestHealth()
        case .calendar:
            if calendarService.permissionState() == .denied {
                openSystemSettings()
            } else {
                await requestCalendar()
            }
        case .notifications:
            if await notificationScheduler.authorizationState() == .denied {
                openSystemSettings()
            } else {
                await requestNotifications()
            }
        case .liveActivities:
            openSystemSettings()
        }
        await refreshPermissions()
    }

    func activateRequiredSensorCollection() async {
        snapshot.settings.sensorCollectionProfile = .balanced
        snapshot.settings.gpsLoggingPreferences = .standard
        await enableLocationCollection(always: true)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// Re-reads the system permission centers when Settings becomes visible.
    /// The saved snapshot is only a cache; iOS permissions can change while
    /// the app is suspended or in Settings.
    func refreshPermissions() async {
        if let permissionRefreshTask {
            await permissionRefreshTask.value
            return
        }
        let generation = dataDeletionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.dataDeletionGeneration == generation {
                    self.permissionRefreshTask = nil
                }
            }
            await self.bootstrap()
            guard !Task.isCancelled, self.dataDeletionGeneration == generation,
                  self.acceptsDataMutation() else { return }
            let revision = self.snapshotRevision
            await self.refreshPermissionStates()
            guard !Task.isCancelled, self.dataDeletionGeneration == generation,
                  self.acceptsDataMutation() else { return }
            self.refreshAppUsageAuthorizationState()
            if self.snapshotRevision != revision {
                await self.persistDeviceLocalSnapshot()
            }
        }
        permissionRefreshTask = task
        await task.value
    }

    /// 설치 후 첫 실행에서만 권한 안내를 띄운다. 권한은 기기마다 다르므로
    /// iCloud로 오가는 스냅샷이 아니라 기기 저장소에 표시 여부를 남긴다.
    func presentPermissionOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        if [PermissionFeature.location, .photos, .calendar, .notifications]
            .allSatisfy({ permissionState(for: $0).isGranted }) {
            if settings.healthEnabled { return }
        }
        let reason: String
        if defaults.bool(forKey: Self.permissionOnboardingKey) {
            guard !settings.healthEnabled,
                  !defaults.bool(forKey: Self.healthPermissionReminderKey)
            else { return }
            defaults.set(true, forKey: Self.healthPermissionReminderKey)
            permissionOnboardingStartFeature = .health
            reason = "missing_health_retry"
        } else {
            permissionOnboardingStartFeature = nil
            reason = "initial"
        }
        isPermissionOnboardingPresented = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "permission_onboarding_presented",
            fields: [
                "reason": reason,
                "health_state": permissionState(for: .health).rawValue,
                "health_enabled": String(settings.healthEnabled),
            ]
        )
    }

    /// 안내 시트가 없을 때 위치 권한이 비어 있으면 시작하자마자 시스템 팝업으로 묻는다.
    /// '항상' 승격 팝업은 iOS가 한 번만 보여 주므로 설치당 한 번만 요청한다.
    func requestMissingLocationPermissionAtLaunch() async {
        guard !isPermissionOnboardingPresented, let sensorService else { return }
        let upgradeKey = "taption.locationAlwaysUpgradeRequested"
        switch sensorService.locationAuthorizationStatus() {
        case .notDetermined:
            break
        case .authorizedWhenInUse:
            guard !UserDefaults.standard.bool(forKey: upgradeKey) else { return }
        default:
            return
        }
        UserDefaults.standard.set(true, forKey: upgradeKey)
        await enableLocationCollection(always: true)
    }

    func presentPermissionOnboarding(for feature: PermissionFeature? = nil) {
        permissionOnboardingStartFeature = feature
        isPermissionOnboardingPresented = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "permission_onboarding_presented",
            fields: [
                "reason": "settings",
                "start_feature": feature?.rawValue ?? "all",
                "health_state": permissionState(for: .health).rawValue,
            ]
        )
    }

    func finishPermissionOnboarding() async {
        UserDefaults.standard.set(true, forKey: Self.permissionOnboardingKey)
        isPermissionOnboardingPresented = false
        permissionOnboardingStartFeature = nil
        await refreshPermissionStates()
        refreshAppUsageAuthorizationState()
        await persist()
    }

    func refreshAppUsageAuthorizationState() {
        let state = screenTimeUsageService.authorizationState
        if appUsageAuthorizationState != state { appUsageAuthorizationState = state }
        let permission: PermissionState = switch state {
        case .approved: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable, .requiresCurrentSystem, .dataAccessUnavailable:
            .unavailable
        }
        if snapshot.settings.permissions[.appUsage] != permission {
            snapshot.settings.permissions[.appUsage] = permission
        }
    }

    func requestAppUsageAuthorization(
        openSettingsIfNeeded: Bool = true
    ) async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            if screenTimeUsageService.authorizationState != .approved {
                try await screenTimeUsageService.requestAuthorization()
            }
            refreshAppUsageAuthorizationState()
            await refreshAppUsageData(
                in: currentDeviceDataSpan,
                showErrors: true
            )
            await persist()
        } catch {
            refreshAppUsageAuthorizationState()
            if openSettingsIfNeeded,
               appUsageAuthorizationState == .dataAccessUnavailable {
                openAppUsageSettings()
            }
            userFacingError = error.localizedDescription
        }
    }

    /// Screen Time은 앱 안에서 권한을 다시 승인할 수 없는 상태가 있다.
    /// 공개된 iOS URL은 앱의 설정 화면까지이므로, 시스템 설정에서 Screen
    /// Time의 앱 및 웹사이트 활동·데이터 공유를 확인하도록 바로 보낸다.
    func openAppUsageSettings() {
        guard let url = URL(
            string: UIApplication.openSettingsURLString
        ) else { return }
        UIApplication.shared.open(url)
    }

    func requestPhotos() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        let state = await photoService.requestAccess()
        snapshot.settings.permissions[.photos] = state
        snapshot.settings.showsPhotos = state.isGranted
        if state.isGranted {
            refreshPhotos()
        }
        await persist()
    }

    func setPhotosEnabled(_ enabled: Bool) async {
        if enabled {
            await requestPhotos()
            return
        }
        snapshot.settings.showsPhotos = false
        snapshot.settings.showsPhotosInWidgets = false
        snapshot.photos = []
        await persist()
    }

    @discardableResult
    func requestCalendar() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        if calendarService.permissionState() == .denied {
            snapshot.settings.permissions[.calendar] = .denied
            openSystemSettings()
            return true
        }
        do {
            let granted = try await calendarService.requestFullAccess()
            let state: PermissionState = granted ? .authorized : .denied
            snapshot.settings.permissions[.calendar] = state
            if granted {
                if snapshot.settings.selectedCalendarIDs.isEmpty {
                    snapshot.settings.selectedCalendarIDs = calendarService
                        .calendars()
                        .map(\.id)
                }
                await refreshCalendarEvents()
                UserDefaults.standard.removeObject(
                    forKey: Self.calendarAutomaticRefreshKey
                )
            } else {
                snapshot.calendarEvents.removeAll()
                calendarStoreRefreshTask?.cancel()
                calendarStoreRefreshTask = nil
                calendarStoreRefreshRequiresWide = false
            }
            await persist()
            return true
        } catch {
            let state = calendarService.permissionState()
            snapshot.settings.permissions[.calendar] = state
            if !state.isGranted {
                snapshot.calendarEvents.removeAll()
                calendarStoreRefreshTask?.cancel()
                calendarStoreRefreshTask = nil
                calendarStoreRefreshRequiresWide = false
            }
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더를 연결하지 못했습니다. \(error.localizedDescription)",
                english: "Could not connect Calendar. \(error.localizedDescription)"
            )
            return false
        }
    }

    func setCalendarEnabled(_ enabled: Bool) async {
        if enabled {
            await requestCalendar()
            return
        }
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        calendarStoreRefreshRequiresWide = false
        snapshot.settings.selectedCalendarIDs = []
        snapshot.calendarEvents = []
        await persist()
    }

    @discardableResult
    func requestHealth() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        TaptionPlanDiagnosticsLogger.shared.record(
            "health_authorization_requested",
            fields: [
                "previous_state": permissionState(for: .health).rawValue,
            ]
        )
        let watchDataSyncProfile =
            TaptionWatchDataSyncProfile.profileAfterHealthAuthorization(
                current: snapshot.settings.watchDataSyncProfile,
                userDidSetProfile: UserDefaults.standard.bool(
                    forKey: Self.watchDataSyncProfileConfiguredKey
                )
            )
        do {
            let granted = try await healthService.requestReadAccess()
            UserDefaults.standard.set(
                true,
                forKey: Self.healthAuthorizationRequestedKey
            )
            snapshot.settings.healthEnabled = granted
            snapshot.settings.permissions[.health] = granted ? .authorized : .denied
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_authorization_completed",
                fields: ["granted": String(granted)]
            )
            await persist()
            // 권한 응답은 배경 데이터 새로고침 상태와 별도로 완료 처리한다.
            // 전체 이력 동기화는 길어질 수 있어 백그라운드에서 진행한다.
            if granted {
                snapshot.settings.watchDataSyncProfile = watchDataSyncProfile
                Task { @MainActor in
                    await refreshHealthData(in: startupHealthSpan, forceRawSync: true)
                    await synchronizeHealthHistory(showErrors: true)
                    await refreshHealthData()
                    await configureHealthBackgroundDeliveryIfNeeded(
                        showErrors: true
                    )
                    startForegroundHealthRefreshIfNeeded()
                    publishWatchPayload()
                    await persist()
                }
            }
            return true
        } catch {
            snapshot.settings.healthEnabled = false
            snapshot.settings.permissions[.health] = .denied
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_authorization_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
            userFacingError = AppLanguagePreference.text(
                korean: "건강 데이터를 연결하지 못했습니다. \(error.localizedDescription)",
                english: "Could not connect Health data. \(error.localizedDescription)"
            )
            return false
        }
    }

    func setHealthEnabled(_ enabled: Bool) async {
        if enabled {
            await requestHealth()
            return
        }
        snapshot.settings.healthEnabled = false
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        await healthService.disableBackgroundDelivery()
        isHealthBackgroundDeliveryConfigured = false
        snapshot.actuals.removeAll {
            $0.source == .healthKit || $0.source == .appleWatch
        }
        sleepSessions = []
        lastHealthRefreshAt = nil
        healthSyncOverview = HealthKitSyncOverview(states: [])
        healthSyncProgress = nil
        await persist()
    }

    func synchronizeHealthHistory(showErrors: Bool = true) async {
        guard settings.healthEnabled, !isHealthHistorySyncRunning else {
            return
        }
        isHealthHistorySyncRunning = true
        defer {
            isHealthHistorySyncRunning = false
            healthSyncProgress = nil
        }
        do {
            healthSyncOverview = try await healthService
                .synchronizeFullHistory { [weak self] progress in
                    await MainActor.run {
                        self?.healthSyncProgress = progress
                    }
                }
            TaptionPlanDiagnosticsLogger.shared.record(
                healthSyncOverview.failedTypeCount == 0
                    ? "health_history_sync_completed"
                    : "health_history_sync_partial",
                level: healthSyncOverview.failedTypeCount == 0
                    ? .info
                    : .error,
                fields: [
                    "types": String(healthSyncOverview.completedTypeCount),
                    "errors": String(healthSyncOverview.failedTypeCount),
                    "samples": String(healthSyncOverview.totalSampleCount),
                    "deletions": String(healthSyncOverview.totalDeletedCount),
                ]
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit history sync failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 전체 이력을 가져오지 못했습니다. \(error.localizedDescription)",
                    english: "Could not import the full Health history. \(error.localizedDescription)"
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_history_sync_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
        }
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            let state = try await notificationScheduler.requestPermission()
            snapshot.settings.permissions[.notifications] = state
            snapshot.settings.notificationsEnabled = state.isGranted
            if state.isGranted {
                try await notificationScheduler.synchronize(
                    plans: snapshot.plans
                )
            }
            await persist()
            return true
        } catch {
            snapshot.settings.permissions[.notifications] =
                await notificationScheduler.authorizationState()
            snapshot.settings.notificationsEnabled = false
            userFacingError = AppLanguagePreference.text(
                korean: "계획 알림을 켜지 못했습니다. \(error.localizedDescription)",
                english: "Could not turn on plan notifications. \(error.localizedDescription)"
            )
            return false
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            await requestNotifications()
            return
        }
        snapshot.settings.notificationsEnabled = false
        await notificationScheduler.cancelAllPlanReminders()
        await persist()
    }

    @discardableResult
    func enableLocationCollection(
        always: Bool = true,
        opensSettingsWhenBlocked: Bool = false
    ) async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        guard let sensorService else {
            snapshot.settings.permissions[.location] = .unavailable
            userFacingError = AppLanguagePreference.text(
                korean: sensorStorageErrorDescription == nil
                    ? "이 기기에서는 위치·동작 센서를 사용할 수 없습니다."
                    : "센서 저장소를 열지 못해 위치 기록을 시작할 수 없습니다. 진단 로그를 확인해주세요.",
                english: sensorStorageErrorDescription == nil
                    ? "Location and motion sensors are unavailable on this device."
                    : "The sensor archive could not be opened, so location recording cannot start. Check the diagnostics log."
            )
            return false
        }

        sensorAvailability = await sensorService.hardwareAvailability()
        var status = sensorService.locationAuthorizationStatus()
        let startedDenied = status == .denied || status == .restricted
        snapshot.settings.permissions[.location] =
            sensorService.locationPermissionState()
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()

        if status == .notDetermined {
            sensorService.requestLocationPermission(always: false)
            for _ in 0..<120 where status == .notDetermined {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                status = sensorService.locationAuthorizationStatus()
            }
        }
        if always, status == .authorizedWhenInUse {
            sensorService.requestLocationPermission(always: true)
            for _ in 0..<120 where status == .authorizedWhenInUse {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                status = sensorService.locationAuthorizationStatus()
            }
        }

        let refreshed = sensorService.locationPermissionState()
        snapshot.settings.permissions[.location] = refreshed
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()
        snapshot.settings.locationEnabled = refreshed.isGranted
        let allowsBackgroundLocation =
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization:
                    sensorService.hasAlwaysLocationAuthorization()
            )
        snapshot.settings.backgroundPreciseLocationEnabled =
            allowsBackgroundLocation
        updateForegroundLiveLocationTracking()

        if refreshed.isGranted {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation: allowsBackgroundLocation
            ))
            isSensorCollecting = true
            receiveSensorWake(.foregroundResume)
            reconcileBackgroundSensorSession()
        }
        // 사용자가 권한 항목을 직접 눌렀는데 시스템 팝업이 더 뜰 수 없는 상태(거부됨·'항상' 승격 팝업을 이미 봄)면
        // 앱 설정으로 바로 보낸다. 시작·자동 수집 경로에서는 설정을 열지 않는다.
        if opensSettingsWhenBlocked,
           startedDenied || (always && !sensorService.hasAlwaysLocationAuthorization()) {
            openSystemSettings()
        }
        publishWatchPayload()
        await persist()
        return true
    }

    @discardableResult
    func requestMapCurrentLocation(
        requiresFreshReading: Bool = false
    ) async -> Bool {
        guard let sensorService else {
            snapshot.settings.permissions[.location] = .unavailable
            userFacingError = AppLanguagePreference.text(
                korean: sensorStorageErrorDescription == nil
                    ? "이 기기에서는 현재 위치를 확인할 수 없습니다."
                    : "센서 저장소를 열지 못해 현재 위치를 기록할 수 없습니다.",
                english: sensorStorageErrorDescription == nil
                    ? "Current location is unavailable on this device."
                    : "The sensor archive could not be opened."
            )
            return false
        }

        var state = sensorService.locationPermissionState()
        if state == .notDetermined {
            sensorService.requestLocationPermission(always: false)
            for _ in 0..<120 where state == .notDetermined {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                state = sensorService.locationPermissionState()
            }
        }
        snapshot.settings.permissions[.location] = state
        guard state.isGranted else {
            presentPermissionOnboarding(for: .location)
            return false
        }

        let persistenceToken = sensorService.persistenceToken()
        let mapConfiguration = sensorCollectionConfiguration(
            profile: settings.sensorCollectionProfile,
            allowsBackgroundLocation: settings.backgroundPreciseLocationEnabled,
            minimumEmissionInterval: requiresFreshReading ? 1 : nil
        )
        if settings.locationEnabled {
            sensorService.startCollection(configuration: mapConfiguration)
            isSensorCollecting = true
            receiveSensorWake(.foregroundResume)
            reconcileBackgroundSensorSession()
        } else {
            await enableLocationCollection(always: false)
            if requiresFreshReading, settings.locationEnabled {
                sensorService.startCollection(configuration: mapConfiguration)
                isSensorCollecting = true
            }
        }
        let cachedAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        )
        if cachedAnchor == nil {
            await hydrateLatestMapLocationAnchor()
        }
        let hasAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        ) != nil
        var receivedFreshReading = false
        if requiresFreshReading || !hasAnchor {
            receivedFreshReading = await sensorService.waitForPersistedReading(
                after: persistenceToken,
                timeout: Self.mapLocationReadingTimeout
            )
            await hydrateLatestMapLocationAnchor()
        }
        if requiresFreshReading {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled
            ))
        }
        let currentAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        )
        return currentAnchor != nil
            && (!requiresFreshReading
                || receivedFreshReading && currentAnchor?.id != cachedAnchor?.id)
    }

    func disableLocationCollection() async {
        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        snapshot.settings.locationEnabled = false
        snapshot.settings.backgroundPreciseLocationEnabled = false
        updateForegroundLiveLocationTracking()
        publishWatchPayload()
        await persist()
    }

    func refreshEnabledData(
        includesCurrentDeviceDay: Bool = false,
        dataSpan: TimeSpan? = nil,
        healthSpan: TimeSpan? = nil,
        includesHealth: Bool = true,
        persistDeviceSnapshot: Bool = true,
        force: Bool = false
    ) async {
        await waitForBootstrapPreparation()
        guard !Task.isCancelled, acceptsDataMutation(), !isRefreshingIntegrations else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selectedDate)
        let refreshKey = [
            selectedScale.rawValue,
            String(dayStart.timeIntervalSinceReferenceDate),
            String(includesCurrentDeviceDay),
            String(settings.hashValue),
            dataSpan.map { String($0.start.timeIntervalSinceReferenceDate) }
                ?? "visible",
            healthSpan.map { String($0.start.timeIntervalSinceReferenceDate) }
                ?? "default",
        ].joined(separator: "|")
        let uptime = ProcessInfo.processInfo.systemUptime
        guard integrationRefreshGate.shouldStart(
            key: refreshKey,
            nowUptime: uptime,
            force: force
        ) else {
            integrationRefreshSkipCount += 1
            if uptime - lastIntegrationSkipLogUptime >= 5 {
                lastIntegrationSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "integration_refresh_skipped",
                    fields: [
                        "reason": "same_window",
                        "count": String(integrationRefreshSkipCount),
                    ]
                )
            }
            return
        }
        let startedAt = uptime
        TaptionPlanDiagnosticsLogger.shared.record(
            "integration_refresh_started",
            fields: [
                "scale": selectedScale.rawValue,
                "day_start": String(dayStart.timeIntervalSince1970),
                "current_day": String(includesCurrentDeviceDay),
            ]
        )
        isRefreshingIntegrations = true
        var calendarRetryForceWide: Bool?
        defer {
            isRefreshingIntegrations = false
            if !Task.isCancelled {
                integrationRefreshGate.commit(
                    key: refreshKey,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "integration_refresh_finished",
                fields: [
                    "actuals": String(snapshot.actuals.count),
                    "travel": String(snapshot.travel.count),
                    "weather": String(snapshot.weather.count),
                    "duration_ms": String(
                        Int(
                            (ProcessInfo.processInfo.systemUptime - startedAt)
                                * 1_000
                        )
                    ),
                ]
            )
            if let calendarRetryForceWide {
                scheduleCalendarStoreRefresh(
                    forceWide: calendarRetryForceWide
                )
            }
        }
        let refreshSpan = dataSpan ?? visibleDataSpan
        let photoSpan = permissionState(for: .photos).isGranted
            && settings.showsPhotos
            ? refreshSpan
            : nil
        let photoTask = photoSpan.map { span in
            Task.detached(priority: .utility) { [photoService] in
                photoService.moments(in: span)
            }
        }
        defer { photoTask?.cancel() }
        if permissionState(for: .calendar).isGranted,
           !settings.selectedCalendarIDs.isEmpty {
            await Task.yield()
            let now = Date.now
            let lastAutomaticRefresh = UserDefaults.standard.object(
                forKey: Self.calendarAutomaticRefreshKey
            ) as? Date
            let refreshesAutomaticRange =
                includesCurrentDeviceDay
                && CalendarSyncPolicy.shouldRefreshAutomaticRange(
                    lastRefresh: lastAutomaticRefresh,
                    now: now
                )
            var completed = true
            for span in CalendarSyncPolicy.refreshSpans(
                requested: refreshSpan,
                includesCurrentDeviceDay: includesCurrentDeviceDay,
                refreshesAutomaticRange: refreshesAutomaticRange,
                now: now
            ) {
                completed = await refreshCalendarEvents(in: span) && completed
            }
            if !completed {
                calendarRetryForceWide = refreshesAutomaticRange
            }
            if refreshesAutomaticRange, completed {
                UserDefaults.standard.set(
                    now,
                    forKey: Self.calendarAutomaticRefreshKey
                )
            }
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if includesHealth && settings.healthEnabled {
            do {
                if try await healthService.authorizationRequestState()
                    == .notDetermined {
                    let completed = try await healthService.requestReadAccess()
                    snapshot.settings.permissions[.health] = completed
                        ? .authorized
                        : .notDetermined
                }
            } catch {
                Self.integrationLogger.error(
                    "HealthKit authorization refresh failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await refreshHealthData(in: healthSpan)
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let appUsageSpan = selectedScale == .day
            ? refreshSpan
            : currentDeviceDataSpan
        await refreshAppUsageData(in: appUsageSpan)
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if settings.locationEnabled
            || settings.healthEnabled
            || settings.weatherEnabled
            || hasPhotoLocations(in: refreshSpan) {
            if includesCurrentDeviceDay {
                await refreshSensorTimeline(containing: .now)
            }
            if !includesCurrentDeviceDay
                || !Calendar.autoupdatingCurrent.isDateInToday(selectedDate) {
                await refreshSensorTimeline(containing: selectedDate)
            }
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if let photoTask, let photoSpan {
            replacePhotos(await photoTask.value, in: photoSpan)
        }
        await refreshFutureWeatherPreviewIfNeeded()
        logAutomaticRecordSummary()
        // Save raw device records locally before any potentially slow cloud
        // request. Automatic interpretations remain separate projections.
        if persistDeviceSnapshot {
            await persistDeviceLocalSnapshot()
        }
    }

    /// Publishes the latest HealthKit/Watch and sensor records before a
    /// routine dashboard is shown. Automatic evidence is ground truth, so a
    /// dashboard must not wait for the next foreground polling interval.
    func refreshConnectedRecordsNow(force: Bool = true) async {
        await bootstrap()
        await refreshEnabledData(
            includesCurrentDeviceDay: true,
            force: force
        )
    }

    func synchronizeCloud(showErrors: Bool = true) async {
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard let cloudSyncService, !isCloudSyncing else {
            if cloudSyncService == nil {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .unsupportedBuild
            }
            return
        }
        isCloudSyncing = true
        if showErrors {
            // Settings에서 사용자가 다시 누른 경우에는 이전 Production 스키마
            // 실패를 캐시하지 않고 즉시 재확인한다. 자동 저장은 반복 요청을
            // 만들지 않도록 서비스의 보호 상태를 유지한다.
            await cloudSyncService.resetSchemaAvailability()
        }
        if await cloudSyncService.isSchemaUnavailable() {
            snapshot.settings.permissions[.cloud] = .unavailable
            cloudUnavailableReason = .schemaMissing
            isCloudSyncing = false
            return
        }
        let (state, reason) = await cloudSyncService.accountAvailability()
        snapshot.settings.permissions[.cloud] = state
        cloudUnavailableReason = reason
        guard state.isGranted else {
            isCloudSyncing = false
            return
        }

        do {
            let localDeviceData = snapshot
            let sourceRevision = snapshotRevision
            let (cloudValue, _) = try await cloudSyncService.synchronize(
                local: Self.cloudPortableSnapshot(snapshot)
            )
            guard sourceRevision == snapshotRevision,
                  acceptsDataMutation() else {
                isCloudSyncing = false
                return
            }
            let committed = preparedCloudMergedSnapshot(
                mergeDeviceLocalData(
                    cloud: cloudValue,
                    local: localDeviceData
                ),
                preservingUpdatedAt: localDeviceData.updatedAt
            )
            var persisted = committed
            persisted.memos.removeAll {
                pendingMapMemoIDs.contains($0.id)
            }
            if try await saveToRepository(
                persisted,
                expectedRevision: sourceRevision
            ) {
                assignCommittedCloudSnapshot(committed)
                publishWidgetPayload()
            }
        } catch is CancellationError {
            // Deletion cancels the registered manual task; do not surface a
            // cancellation as a failed user-initiated sync.
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
                || error is RepositoryError
                    && (error as? RepositoryError) == .cloudSchemaUnavailable {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .schemaMissing
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_sync_schema_unavailable",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
                Self.integrationLogger.error(
                    "CloudKit production schema is unavailable; local data remains authoritative"
                )
            } else if showErrors {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_sync_failed",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
                userFacingError = AppLanguagePreference.text(
                    korean: "iCloud와 동기화하지 못했습니다. \(error.localizedDescription)",
                    english: "Could not sync with iCloud. \(error.localizedDescription)"
                )
            }
        }
        isCloudSyncing = false
    }

    /// 달력 지표용: 그 달 날짜별 걸음 수. 건강 앱(HealthKit) 일별 합계를 우선하고, 센서 기록의 누적 걸음 수
    /// (그날 최댓값)가 더 크면 그 값을 쓴다. 둘 다 없으면 빈 딕셔너리.
    func calendarDailyStepCounts(month: Date) async -> [Date: Double] {
        let calendar = Calendar.autoupdatingCurrent
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first) else { return [:] }
        let health = (try? await healthService.dailyStepCounts(from: first, to: min(end, .now), calendar: calendar)) ?? [:]
        var sensor: [Date: Double] = [:]
        if let sensorService,
           let readings = try? await sensorService.archivedReadings(in: TimeSpan(start: first, end: end)) {
            for reading in readings {
                guard let steps = reading.stepCount, steps > 0 else { continue }
                let day = calendar.startOfDay(for: reading.timestamp)
                sensor[day] = max(sensor[day] ?? 0, Double(steps))
            }
        }
        // 걸음 수가 0으로 보일 때 원인(건강 앱 값 없음/센서 값 없음)을 로그로 구분할 수 있게 남긴다.
        TaptionPlanDiagnosticsLogger.shared.record(
            "calendar_steps",
            metrics: ["health_days": Double(health.count), "sensor_days": Double(sensor.count)]
        )
        var merged = MapHomeCalendarTimeTotalsPolicy.mergedStepCounts(health: health, sensor: sensor)
        // 오늘 걸음은 센서 기록(활동이 끝나야 저장됨)이 늦으므로 CMPedometer로 바로 읽어 더 큰 값을 쓴다.
        let today = calendar.startOfDay(for: .now)
        if calendar.isDate(first, equalTo: today, toGranularity: .month),
           let live = await Self.todayPedometerSteps(from: today, calendar: calendar) {
            merged[today] = max(merged[today] ?? 0, live)
        }
        return merged
    }

    private nonisolated(unsafe) static let todayPedometer = CMPedometer()

    /// 자정부터 지금까지의 걸음 수(CMPedometer). 지원되지 않거나 실패하거나 3초 안에 응답이 없으면 nil.
    /// 측정기를 계속 들고 있어야 응답이 오고, 시간 제한이 없으면 달력 계산이 영원히 멈출 수 있다.
    private nonisolated static func todayPedometerSteps(from start: Date, calendar: Calendar) async -> Double? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            let once = PedometerResumeOnce(continuation)
            todayPedometer.queryPedometerData(from: start, to: .now) { data, _ in
                once.resume(data.map { Double($0.numberOfSteps.intValue) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
    }

    func startManualCloudSync() {
        let previous = cloudSyncTask
        previous?.cancel()
        cloudSyncTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.synchronizeCloud()
        }
    }

    func selectCatCoat(_ coat: CatCoat) {
        selectedCatCoat = coat
        snapshot.settings.catStyle = coat.catStyle
        publishWatchPayload()
        Task { await persist() }
    }

    func setStartScale(_ scale: TimeScale) {
        let scheduleScale = scale.scheduleEquivalent
        snapshot.settings.startScale = scheduleScale.timelineLevel
        selectedScale = scheduleScale
        Task { await persist() }
    }

    func setRememberLastScale(_ enabled: Bool) {
        snapshot.settings.rememberLastScale = enabled
        if enabled {
            snapshot.settings.startScale = selectedScale.timelineLevel
        }
        Task { await persist() }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard snapshot.settings.reduceMotion != enabled else { return }
        snapshot.settings.reduceMotion = enabled
        publishWatchPayload()
        Task { await persist() }
    }

    func setSensorCollectionProfile(
        _ profile: SensorCollectionProfile
    ) {
        let intervalSeconds = Int(profile.interval)
        let batteryMinimal = profile == .batterySaver
        guard snapshot.settings.sensorCollectionProfile != profile
                || snapshot.settings.gpsLoggingPreferences.intervalSeconds != intervalSeconds
                || snapshot.settings.gpsLoggingPreferences.isBatteryMinimal != batteryMinimal else {
            return
        }
        snapshot.settings.sensorCollectionProfile = profile
        snapshot.settings.gpsLoggingPreferences.intervalSeconds = intervalSeconds
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal = batteryMinimal
        if settings.locationEnabled,
           permissionState(for: .location).isGranted,
           let sensorService {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: profile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled
            ))
            isSensorCollecting = true
            reconcileBackgroundSensorSession()
        }
        Task { await persist() }
    }

    func setGPSLoggingBatteryMinimal(_ enabled: Bool) {
        guard snapshot.settings.gpsLoggingPreferences.isBatteryMinimal != enabled else {
            return
        }
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal = enabled
        if enabled {
            snapshot.settings.sensorCollectionProfile = .batterySaver
            snapshot.settings.gpsLoggingPreferences.intervalSeconds =
                GPSLoggingPreferences.batteryMinimalIntervalSeconds
        } else {
            let interval = snapshot.settings.gpsLoggingPreferences.intervalSeconds
            if interval >= GPSLoggingPreferences.batteryMinimalIntervalSeconds {
                snapshot.settings.sensorCollectionProfile = .balanced
                snapshot.settings.gpsLoggingPreferences.intervalSeconds =
                    GPSLoggingPreferences.Preset.balanced.intervalSeconds
            } else {
                snapshot.settings.sensorCollectionProfile = sensorCollectionProfile(
                    for: interval
                )
            }
        }
        refreshActiveGPSLoggingPreferences()
        Task { await persist() }
    }

    func setGPSLoggingIntervalSeconds(_ seconds: Int) {
        let clamped = GPSLoggingPreferences.clampedSeconds(seconds)
        guard snapshot.settings.gpsLoggingPreferences.intervalSeconds != clamped
                || snapshot.settings.gpsLoggingPreferences.isBatteryMinimal else {
            return
        }
        snapshot.settings.gpsLoggingPreferences.intervalSeconds = clamped
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal =
            clamped == GPSLoggingPreferences.batteryMinimalIntervalSeconds
        snapshot.settings.sensorCollectionProfile = sensorCollectionProfile(
            for: clamped
        )
        refreshActiveGPSLoggingPreferences()
        Task { await persist() }
    }

    func setGPSLoggingPreset(_ preset: GPSLoggingPreferences.Preset) {
        let profile: SensorCollectionProfile
        switch preset {
        case .batterySaver: profile = .batterySaver
        case .balanced: profile = .balanced
        case .realtime: profile = .accuracy
        }
        setSensorCollectionProfile(profile)
    }

    private func sensorCollectionProfile(for intervalSeconds: Int) -> SensorCollectionProfile {
        switch intervalSeconds {
        case 900...: .batterySaver
        case 120...600: .balanced
        default: .accuracy
        }
    }

    @available(*, deprecated, message: "Use setGPSLoggingIntervalSeconds")
    func setGPSLoggingIntervalMinutes(_ minutes: Int) {
        setGPSLoggingIntervalSeconds(minutes * 60)
    }

    private func refreshActiveGPSLoggingPreferences() {
        if activeTrackingSession != nil {
            sensorService?.updateTrackingPreferences(
                settings.gpsLoggingPreferences
            )
            return
        }
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else { return }
        sensorService.startCollection(
            configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled,
                minimumEmissionInterval:
                    settings.gpsLoggingPreferences.interval
            )
        )
        isSensorCollecting = true
        reconcileBackgroundSensorSession()
    }

    private func sensorCollectionConfiguration(
        profile: SensorCollectionProfile,
        allowsBackgroundLocation: Bool,
        minimumEmissionInterval: TimeInterval? = nil
    ) -> SensorCollectionConfiguration {
        var configuration = SensorCollectionConfiguration.configured(
            for: profile,
            allowsBackgroundLocation: allowsBackgroundLocation
        )
        if let minimumEmissionInterval {
            configuration.minimumEmissionInterval = minimumEmissionInterval
        } else {
            configuration.minimumEmissionInterval =
                settings.gpsLoggingPreferences.interval
        }
        return configuration
    }

    private func receiveSensorWake(_ reason: SensorWakeReason) {
        let accepted = sensorBackgroundCoordinator.receiveWake(reason)
        syncSensorBackgroundState()
        Self.integrationLogger.notice(
            "Sensor wake: reason=\(reason.rawValue, privacy: .public), accepted=\(accepted, privacy: .public), token=\(self.sensorSaveToken, privacy: .public)"
        )
        if accepted {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_background_wake",
                fields: [
                    "reason": reason.rawValue,
                    "save_token": String(sensorSaveToken),
                ]
            )
        }
    }

    private func syncSensorBackgroundState() {
        let previousState = sensorCollectionSessionState
        if sensorCollectionSessionState != sensorBackgroundCoordinator.sessionState {
            sensorCollectionSessionState = sensorBackgroundCoordinator.sessionState
        }
        if sensorCollectionSessionID != sensorBackgroundCoordinator.sessionID {
            sensorCollectionSessionID = sensorBackgroundCoordinator.sessionID
        }
        if sensorCollectionStartedAt != sensorBackgroundCoordinator.sessionStartedAt {
            sensorCollectionStartedAt = sensorBackgroundCoordinator.sessionStartedAt
        }
        if lastSensorWakeReason != sensorBackgroundCoordinator.lastWakeReason {
            lastSensorWakeReason = sensorBackgroundCoordinator.lastWakeReason
        }
        if lastSensorSavedAt != sensorBackgroundCoordinator.lastSavedAt {
            lastSensorSavedAt = sensorBackgroundCoordinator.lastSavedAt
        }
        if sensorSaveToken != sensorBackgroundCoordinator.saveToken {
            sensorSaveToken = sensorBackgroundCoordinator.saveToken
        }
        if previousState != sensorCollectionSessionState {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_collection_state",
                fields: [
                    "state": sensorCollectionSessionState.rawValue,
                    "save_token": String(sensorSaveToken),
                    "saved_at": lastSensorSavedAt.map {
                        String($0.timeIntervalSince1970)
                    } ?? "none",
                ]
            )
        }
    }

    func setWatchAccelerationProfile(
        _ profile: TaptionWatchAccelerationProfile
    ) {
        guard snapshot.settings.watchAccelerationProfile != profile else {
            return
        }
        snapshot.settings.watchAccelerationProfile = profile
        publishWatchPayload()
        Task { await persist() }
    }

    func setWatchDataSyncProfile(
        _ profile: TaptionWatchDataSyncProfile
    ) {
        UserDefaults.standard.set(
            true,
            forKey: Self.watchDataSyncProfileConfiguredKey
        )
        guard snapshot.settings.watchDataSyncProfile != profile else {
            return
        }
        snapshot.settings.watchDataSyncProfile = profile
        publishWatchPayload()
        Task { await persist() }
    }

    func requestWatchDataSync(source: String = "settings_button") {
        scheduleWatchHealthRefresh()
    }

    @ObservationIgnored private var watchHealthRefreshTask: Task<Void, Never>?

    private func scheduleWatchHealthRefresh() {
        guard isBootstrapped, isSceneActive, !isAppLocked, watchHealthRefreshTask == nil else { return }
        watchHealthRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.watchHealthRefreshTask = nil }
            let action = TaptionWatchHealthLaunchPolicy.action(
                isPaired: self.watchConnectivityService.isWatchPaired,
                healthEnabled: self.settings.healthEnabled,
                hasRequestedAuthorization: UserDefaults.standard.bool(
                    forKey: Self.healthAuthorizationRequestedKey
                )
            )
            guard self.isSceneActive, !self.isAppLocked else { return }
            switch action {
            case .requestAuthorization:
                await self.requestHealth()
            case .refresh:
                do {
                    if try await self.healthService.authorizationRequestState() == .notDetermined {
                        await self.requestHealth()
                        return
                    }
                } catch {
                    // Already connected HealthKit remains queryable if request-status lookup fails.
                }
                await self.refreshHealthData(in: self.startupHealthSpan, showErrors: false, forceRawSync: true)
                await self.persistDeviceLocalSnapshot()
            case .none:
                break
            }
        }
    }

    private func applyAppleWatchDataSyncLiveFailure(requestID: String) {
        guard appleWatchDataSyncRequestID == requestID,
              appleWatchDataSyncRequestedAt != nil else { return }
        appleWatchDataSyncRequestStatus = .backgroundQueued
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_data_sync_live_failure_applied",
            level: .notice,
            fields: ["request_id": requestID]
        )
    }

    func refreshAppleWatchConnectionState() {
        watchConnectivityService.refreshConnectionState()
        refreshWatchLaunchReport()
    }

    /// 페어링 완료 이벤트에서도 HealthKit 연결을 확인한다.
    func applyAppleWatchConnectionState(_ state: AppleWatchConnectionState) {
        let changed = appleWatchConnectionState != state
        scheduleWatchHealthRefresh()
        if changed {
            appleWatchConnectionState = state
            // Reachability is not part of the Watch payload itself. Reset the
            // identity so a newly reachable companion receives the latest
            // queue once, without restoring the old duplicate-send loop.
            lastWatchPayloadIdentity = nil
            publishWatchPayload()
        }
        // 설치를 한 번 확인했으면 사용자가 나중에 지우더라도 다시 권하지 않는다.
        guard state == .background || state == .reachable,
              !hasSeenWatchAppInstalled else {
            return
        }
        watchOnboardingStore.markWatchAppInstalled()
        hasSeenWatchAppInstalled = true
    }

    /// 지금 보여 줄 첫 실행 안내. 없으면 아무것도 띄우지 않는다.
    var appleWatchOnboardingPrompt: AppleWatchOnboardingPrompt? {
        nil
    }

    /// Watch 앱 설치와 무관한 HealthKit 수신 안내.
    var appleWatchCompanionRow: AppleWatchCompanionRow {
        AppleWatchCompanionRow(
            subtitle: AppLanguagePreference.text(
                korean: "iPhone 건강 앱에 동기화된 Watch 데이터를 가져옵니다",
                english: "Imports Watch data synced to the iPhone Health app"
            ),
            value: settings.healthEnabled
                ? AppLanguagePreference.text(korean: "건강 연결", english: "Health connected")
                : AppLanguagePreference.text(korean: "권한 필요", english: "Permission needed"),
            detail: AppLanguagePreference.text(
                korean: "별도 Watch 앱 없이 앱을 열면 조회합니다. Watch에서 iPhone으로 동기화되는 시점에 따라 최신 데이터가 늦게 도착할 수 있습니다.",
                english: "Data is fetched when you open the app, with no separate Watch app. The latest data may arrive late depending on when the Watch syncs to the iPhone."
            )
        )
    }

    /// 한 번 닫으면 그 안내는 다시 뜨지 않는다.
    func dismissAppleWatchPrompt(_ prompt: AppleWatchOnboardingPrompt) {
        guard !dismissedAppleWatchPrompts.contains(prompt) else { return }
        watchOnboardingStore.dismiss(prompt)
        dismissedAppleWatchPrompts.insert(prompt)
    }

    func refreshWatchLaunchReport() {
        watchLaunchReport = WatchLaunchReportStore.read()
    }

    func clearWatchLaunchReport() {
        WatchLaunchReportStore.clear()
        watchLaunchReport = nil
    }

    func startTracking(_ kind: TrackingKind) async {
        guard kind != .automatic else { return }
        if !settings.locationEnabled
            || !permissionState(for: .location).isGranted {
            await enableLocationCollection(always: true)
        }
        guard let sensorService,
              permissionState(for: .location).isGranted else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 권한을 허용해야 걷기·달리기 경로를 기록할 수 있습니다.",
                english: "Allow location access to record walking and running routes."
            )
            return
        }
        if activeTrackingSession != nil {
            await stopTracking()
        }
        // Exercise records remain unlinked until the user taps an item in the
        // detail panel. Time/category overlap is not an implicit relationship.
        let linkedPlanID: UUID? = nil
        let session = sensorService.beginTracking(
            kind: kind,
            linkedPlanID: linkedPlanID,
            preferences: settings.gpsLoggingPreferences
        )
        activeTrackingSession = session
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_started",
            fields: ["kind": kind.rawValue]
        )
        trackingSessionWasRecovered = false
        TrackingSessionRecoveryStore.save(session)
        lastTrackingSessionRecoveryPersistAt = .now
        liveRouteState = LiveRouteState(
            session: session,
            readings: [],
            lastUpdatedAt: .now
        )

    }

    func stopTracking() async {
        guard let completed = sensorService?.endTracking()
            ?? activeTrackingSession.map({ session in
                var value = session
                value.endedAt = .now
                return value
            }) else {
            return
        }
        finalizeTrackingSession(completed)
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_stopped",
            fields: [
                "kind": completed.kind.rawValue,
                "duration_seconds": String(
                    Int((completed.endedAt ?? .now).timeIntervalSince(
                        completed.startedAt
                    ))
                ),
            ]
        )
        TrackingSessionRecoveryStore.clear()
        lastTrackingSessionRecoveryPersistAt = nil
        activeTrackingSession = nil
        trackingSessionWasRecovered = false
        liveRouteState.session = nil
        scheduleSensorAnalysis(
            containing: completed.startedAt,
            immediately: true
        )
        if let endedAt = completed.endedAt,
           !Calendar.autoupdatingCurrent.isDate(
               completed.startedAt,
               inSameDayAs: endedAt
           ) {
            scheduleSensorAnalysis(containing: endedAt, immediately: true)
        }
    }

    func liveSensorReadings(in span: TimeSpan) -> [SensorReading] {
        liveRouteState.readings.filter { span.contains($0.timestamp) }
    }

    func mergingLiveSensorReadings(
        _ archived: [SensorReading],
        in span: TimeSpan
    ) -> [SensorReading] {
        let cacheKey = LiveMergeCacheKey(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            archivedCount: archived.count,
            archivedFirstID: archived.first?.id,
            archivedLastID: archived.last?.id,
            archivedFirstTimestamp: archived.first?.timestamp,
            archivedLastTimestamp: archived.last?.timestamp,
            liveCount: liveRouteState.readings.count,
            liveLastUpdatedAt: liveRouteState.lastUpdatedAt
        )
        if liveMergeCacheKey == cacheKey {
            return liveMergeCacheValue
        }

        let live = liveSensorReadings(in: span)
        guard !live.isEmpty else {
            liveMergeCacheKey = cacheKey
            liveMergeCacheValue = archived
            return archived
        }

        // Both sources are chronological: the archive reader and the live
        // route append path preserve timestamp order. Merge them linearly so
        // a live GPS tick does not sort and allocate the entire route again.
        var merged: [SensorReading] = []
        merged.reserveCapacity(archived.count + live.count)
        var seen = Set<UUID>()
        seen.reserveCapacity(archived.count + live.count)
        var archivedIndex = 0
        var liveIndex = 0

        while archivedIndex < archived.count || liveIndex < live.count {
            let takeArchived: Bool
            if liveIndex == live.count {
                takeArchived = true
            } else if archivedIndex == archived.count {
                takeArchived = false
            } else {
                // Keep the archive first for equal timestamps, matching the
                // previous stable-sort behavior when an ID is duplicated.
                takeArchived = archived[archivedIndex].timestamp
                    <= live[liveIndex].timestamp
            }

            let reading: SensorReading
            if takeArchived {
                reading = archived[archivedIndex]
                archivedIndex += 1
            } else {
                reading = live[liveIndex]
                liveIndex += 1
            }
            if seen.insert(reading.id).inserted {
                merged.append(reading)
            }
        }
        liveMergeCacheKey = cacheKey
        liveMergeCacheValue = merged
        return merged
    }

    func setWidgetPhotosVisible(_ visible: Bool) {
        snapshot.settings.showsPhotosInWidgets =
            visible && permissionState(for: .photos).isGranted
        Task { await persist() }
    }

    func refreshWidgetNow() {
        publishWidgetPayload()
    }

    func exportTodaySensorRawURL() async throws -> URL {
        let now = Date.now
        let day = await planDayDataSnapshot(for: now, forceReload: true, refreshRawReadings: true)
        let readings = TodaySensorRawExport.readings(day.readings, on: now)
        let payload = TodaySensorRawExport(day: day.day, isComplete: day.isComplete,
            readings: readings, travel: day.travel)
        return try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaptionPlanRawExport", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Taption-Today-Raw-\(UUID().uuidString).json")
            try JSONEncoder().encode(payload).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }.value
    }

    func exportSnapshotURL() throws -> URL {
        let data = try SnapshotExporter.jsonData(snapshot)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaptionPlanExport", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("Taption-Plan-Data.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportDiagnosticsToICloud() async {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        diagnosticsExportStatus = AppLanguagePreference.text(
            korean: "전송 중",
            english: "Exporting"
        )
        defer { isExportingDiagnostics = false }
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation(
            "diagnostics_export",
            fields: ["destination": "icloud_drive"]
        )
        var iphoneLogBytes = 0
        var watchLogBytes = 0
        do {
            logger.record("diagnostics_export_requested")
            let watchLog = await watchConnectivityService
                .requestDiagnosticsLog()
                ?? WatchLaunchReportStore.read()?.report
            let builder = try TaptionPlanDiagnosticsLogPackageBuilder
                .applicationSupport()
            let iphoneLog = logger.combinedLog()
            iphoneLogBytes = iphoneLog.utf8.count
            watchLogBytes = watchLog?.utf8.count ?? 0
            let package = try builder.makePackage(
                summary: diagnosticsSummary,
                iphoneLog: iphoneLog,
                watchLog: watchLog
            )
            let destination = try await Task.detached(priority: .utility) {
                try TaptionPlanDiagnosticsICloudExporter().export(package)
            }.value
            diagnosticsExportStatus = AppLanguagePreference.text(
                korean: "전송됨",
                english: "Exported"
            )
            let defaults = UserDefaults(
                suiteName: TaptionWidgetSharedStore.appGroupIdentifier
            ) ?? .standard
            defaults.set(
                destination.lastPathComponent,
                forKey: Self.diagnosticsLatestFileKey
            )
            defaults.set(
                Date.now,
                forKey: Self.diagnosticsLatestSavedAtKey
            )
            logger.record(
                "diagnostics_export_completed",
                fields: [
                    "file": destination.lastPathComponent,
                    "latest_pointer": TaptionDiagnosticsLatestLogManifest.fileName,
                ]
            )
            logger.finishOperation(
                operation,
                outcome: "success",
                fields: [
                    "file": destination.lastPathComponent,
                    "iphone_log_bytes": String(iphoneLogBytes),
                    "watch_log_bytes": String(watchLogBytes),
                ]
            )
        } catch {
            diagnosticsExportStatus = AppLanguagePreference.text(
                korean: "실패",
                english: "Failed"
            )
            logger.finishOperation(
                operation,
                outcome: "failure",
                fields: [
                    "iphone_log_bytes": String(iphoneLogBytes),
                    "watch_log_bytes": String(watchLogBytes),
                ],
                error: error
            )
            logger.record(
                "diagnostics_export_failed",
                level: .error,
                fields: TaptionDiagnosticError.compactFields(for: error)
            )
            userFacingError = error.localizedDescription
        }
    }

    private var diagnosticsSummary: [String: String] {
        let bundle = Bundle.main
        var summary: [String: String] = [
            "app_version": bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "build": bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "plans": String(snapshot.plans.count),
            "actuals": String(snapshot.actuals.count),
            "travel": String(snapshot.travel.count),
            "places": String(snapshot.places.count),
            "weather": String(snapshot.weather.count),
            "calendar_events": String(snapshot.calendarEvents.count),
            "photos": String(snapshot.photos.count),
            "memos": String(snapshot.memos.count),
            "watch_connection": appleWatchConnectionState.rawValue,
            "sensor_collecting": String(isSensorCollecting),
            "sensor_service_available": String(sensorService != nil),
            "sensor_stream_live": String(
                sensorService?.isCollectionLive() == true
            ),
            "sensor_archive_error": sensorStorageErrorDescription
                ?? sensorService?.lastPersistenceErrorDescription
                ?? "none",
            "sensor_latest_persisted_at": sensorService?
                .latestPersistedReadingDate()
                .map { String($0.timeIntervalSince1970) } ?? "none",
            "location_enabled": String(settings.locationEnabled),
            "health_enabled": String(settings.healthEnabled),
            "cloud_status": cloudStatusText,
            "cloud_status_reason": cloudUnavailableReason?
                .statusLabel(preference: .korean) ?? "없음",
            "widget_sync": widgetSyncStatusText,
            "integration_refresh_skipped": String(integrationRefreshSkipCount),
            "widget_payload_skipped": String(widgetPayloadSkipCount),
            "watch_payload_skipped": String(watchPayloadSkipCount),
        ]
        summary.merge(
            TaptionPlanDiagnosticsSession.latestSummary(),
            uniquingKeysWith: { _, new in new }
        )
        summary.merge(
            TaptionPlanDiagnosticsTravelSummary.fields(for: snapshot.travel),
            uniquingKeysWith: { _, new in new }
        )
        return summary
    }

    /// 이 기기의 모든 기록을 지운다. `includingBackups`가 true일 때만 iCloud Drive의 백업 파일도 지운다
    /// (되돌릴 수 없으므로 호출하는 화면이 사용자 확인을 받아야 한다).
    func deleteAllUserData(includingBackups: Bool = false) async {
        guard acceptsDataMutation() || (isStartupSnapshotPartial && allowsRepositoryLoadAttempt()) else { return }
        isDeletingUserData = true
        let deletionCutoff = Date.now
        dataDeletionGeneration = TaptionDataDeletionFence.advance(
            at: deletionCutoff
        )
        defer {
            sensorService?.finishDataDeletion()
            TaptionDataDeletionFence.finish(
                generation: dataDeletionGeneration
            )
            isDeletingUserData = false
        }
        foregroundPreparationGeneration &+= 1
        let pendingTasks = [
            bootstrapTask,
            startupSettingsTask,
            bootstrapPreparationTask,
            permissionRefreshTask,
            foregroundPreparationTask,
            foregroundRefreshTask,
            deferredVisibleRefreshTask,
            foregroundHealthRefreshTask,
            calendarStoreRefreshTask,
            selectedDateRefreshTask,
            widgetReloadFollowupTask,
            calibrationNoticeTask,
            sensorAnalysisDebounceTask,
            liveWeatherRefreshTask,
            pendingDeviceLocalPersistTask,
            postSaveRefreshTask,
            cloudSyncTask,
        ].compactMap { $0 }
        pendingTasks.forEach { $0.cancel() }
        let pendingSensorTimeline = sensorTimelineTask
        pendingSensorTimeline?.cancel()
        bootstrapTask = nil
        startupSettingsTask = nil
        hasPreparedStartupSettings = false
        isStartupSnapshotPartial = false
        bootstrapPreparationTask = nil
        permissionRefreshTask = nil
        needsBootstrapPreparation = false
        foregroundPreparationTask = nil
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask = nil
        calendarStoreRefreshTask = nil
        calendarStoreRefreshRequiresWide = false
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask = nil
        widgetReloadFollowupTask = nil
        calibrationNoticeTask = nil
        sensorAnalysisDebounceTask = nil
        sensorAnalysisTaskGeneration &+= 1
        pendingSensorAnalysisRevisions.removeAll(keepingCapacity: false)
        liveWeatherRefreshTask = nil
        pendingDeviceLocalPersistTask = nil
        postSaveRefreshTask = nil
        postSaveRefreshRequested = false
        cloudSyncTask = nil
        _ = airPodsActivityService.stop(at: deletionCutoff)
        await sensorService?.prepareForDataDeletion()
        await dayLoadCoordinator?.invalidateAll()
        MapHomeDayCacheEviction.removeAll()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        for task in pendingTasks { await task.value }
        _ = await pendingSensorTimeline?.value
        while isHealthRefreshRunning || activeDataMutationCount > 0 {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "데이터 삭제가 취소되었습니다. 다시 시도해 주세요.",
                    english: "Data deletion was cancelled. Please try again."
                )
                return
            }
        }
        _ = voiceMemoRecorder.stop()
        voiceMemoPlayer.stop()
        isRecordingVoiceMemo = false
        playingVoiceAttachmentID = nil
        await liveActivityController.concealAll()
        TrackingSessionRecoveryStore.clear()
        activeTrackingSession = nil
        trackingSessionWasRecovered = false
        liveRouteState = .empty
        isSensorCollecting = false
        await notificationScheduler.cancelAllPlanReminders()
        var empty = TaptionDataSnapshot.empty
        empty.categories = CategoryCatalog.builtIn
        empty.settings.permissions = snapshot.settings.permissions
        empty.settings.permissions[.cloud] =
            snapshot.settings.permissions[.cloud] ?? .notDetermined
        empty.settings.cloudResetAt = .now
        snapshot = empty
        pendingSetupCategoryIDs = Set(empty.categories.map(\.id))
        isEditingSetupCategories = false
        selectedGroupPlanID = nil
        groupNavigationPath = []
        memoEntry = nil
        sleepSessions = []
        pendingMapMemoIDs.removeAll()
        finalizedTrackingSessionIDs.removeAll()
        latestWatchSummaryVersion.removeAll()
        appliedWatchSummaryVersion.removeAll()
        restoredWatchSummarySessions.removeAll()
        Self.clearPersistedWatchSummaryHighWater()
        finalizedWatchSummarySessionIDs.removeAll()
        pendingWatchActivitySuggestion = nil
        latestSensorReading = nil
        latestMapAnchorHydratedDay = nil
        lastLiveEnvironmentPoint = nil
        lastLiveEnvironmentAt = nil
        lastLiveEnvironmentFailureAt = nil
        lastReviewArchiveRefreshAt = nil
        UserDefaults.standard.removeObject(
            forKey: Self.calendarAutomaticRefreshKey
        )
        liveMergeCacheKey = nil
        liveMergeCacheValue = []
        sensorRefreshFingerprints.removeAll()
        lastWatchHealthSnapshotCapturedAt = nil
        lastWatchHealthSnapshotRawRetryAt = nil
        lastWatchHealthSnapshotRawRetryFingerprint = nil
        lastWatchHealthSnapshotRawRetryAttemptAt = nil
        var deletionFailures: [String] = []
        func recordDeletionFailure(_ label: String, _ error: Error) {
            deletionFailures.append(label)
            Self.integrationLogger.error(
                "Data deletion failed: \(label, privacy: .public), \(error.localizedDescription, privacy: .public)"
            )
        }
        if let cloudSyncService {
            do {
                try await cloudSyncService.deleteSnapshot()
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iCloud 동기화 기록", english: "iCloud sync records"),
                    error)
            }
        } else if permissionState(for: .cloud).isGranted {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "iCloud 동기화 기록", english: "iCloud sync records"),
                CancellationError())
        }
        do {
            try await repository.deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "앱 기록", english: "App records"),
                error)
        }
        if let sensorService {
            do {
                try await sensorService.deleteArchivedReadings(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iPhone 센서 원본", english: "iPhone sensor source data"),
                    error)
            }
        }
        do {
            try await healthService.deleteImportedData(
                generation: dataDeletionGeneration
            )
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "건강 데이터 원본", english: "Health source data"),
                error)
        }
        healthSyncOverview = HealthKitSyncOverview(states: [])
        lastHealthRefreshAt = nil
        if let rawDeviceDataArchive {
            do {
                try await rawDeviceDataArchive.deleteAll(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "기기 원본", english: "Device source data"),
                    error)
            }
        }
        if watchConnectivityService.watchDataDeletionRequired(),
           !(await watchConnectivityService.requestWatchDataDeletion(
               generation: dataDeletionGeneration
           )) {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "Watch 본체 확인", english: "Watch device check"),
                CancellationError())
        }
        if let dayDatabase {
            do {
                try await dayDatabase.deleteAll(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "날짜별 원본", english: "Per-day source data"),
                    error)
            }
        }
        if let biometricProtectedSnapshotStore {
            do {
                try biometricProtectedSnapshotStore.deleteStoredSnapshot()
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "보호된 스냅샷", english: "Protected snapshot"),
                    error)
            }
        }
        biometricDataProtectionStatus = biometricProtectedSnapshotStore?.status
            ?? .unavailable
        if includingBackups {
            backupActivity = .deleting
            defer { backupActivity = .idle }
            do {
                try await deleteAllBackupFiles(confirmed: true)
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iCloud 백업", english: "iCloud backup"),
                    error)
            }
        }
        securityStatus = securityService?.status ?? securityStatus
        appleWatchDataReceiptStore.clear()
        watchConnectivityService.clearLocalState()
        appleWatchLastDataReceivedAt = nil
        appleWatchReceivedDataKinds = []
        WatchActivityConfirmationStore.clear()
        WatchActivityLearningStore.clear()
        WatchLaunchReportStore.clear()
        WatchDiagnosticsLogStore.clear()
        watchLaunchReport = nil
        do {
            try TaptionWidgetSharedStore.deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "위젯 공유 기록", english: "Widget shared records"),
                error)
        }
        do {
            try TaptionPlanDiagnosticsLogPackageBuilder.applicationSupport()
                .deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "진단 로그", english: "Diagnostics log"),
                error)
        }
        do {
            try TaptionPlanDiagnosticsICloudExporter().deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "iCloud 진단 로그", english: "iCloud diagnostics log"),
                error)
        }
        let diagnosticsDefaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ) ?? .standard
        diagnosticsDefaults.removeObject(forKey: Self.diagnosticsLatestFileKey)
        diagnosticsDefaults.removeObject(forKey: Self.diagnosticsLatestSavedAtKey)
        diagnosticsExportStatus = AppLanguagePreference.text(
            korean: "준비됨",
            english: "Ready"
        )
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            try? FileManager.default.removeItem(
                at: applicationSupport.appendingPathComponent(
                    "TaptionPlan/VoiceMemos",
                    isDirectory: true
                )
            )
        }
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent(
                "TaptionPlanExport",
                isDirectory: true
            )
        )
        TaptionPlanDiagnosticsLogger.shared.clear()
        // The replacement snapshot is post-deletion state, so release the
        // cross-process fence before writing it. `isDeletingUserData` still
        // blocks ordinary mutations until this method returns.
        TaptionDataDeletionFence.finish(
            generation: dataDeletionGeneration
        )
        if deletionFailures.isEmpty,
           !(await persist(allowingDeletion: true)) {
            deletionFailures.append(AppLanguagePreference.text(
                korean: "빈 저장본",
                english: "Empty snapshot"
            ))
        }
        if !deletionFailures.isEmpty {
            userFacingError = AppLanguagePreference.text(
                korean: "일부 데이터를 삭제하지 못했습니다: ",
                english: "Some data could not be deleted: "
            ) + deletionFailures.joined(separator: ", ")
            TaptionPlanDiagnosticsLogger.shared.record(
                "user_data_deletion_incomplete",
                level: .error,
                fields: ["stores": deletionFailures.joined(separator: ",")]
            )
        }
    }

    func resetSettingsToDefaults() async {
        await bootstrap()
        await waitForBootstrapPreparation()
        guard !repositoryLoadFailed else { return }

        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        await notificationScheduler.cancelAllPlanReminders()

        let defaults = AppFeatureSettings.defaults
        var reset = snapshot
        reset.settings = defaults
        snapshot = reset
        selectedScale = TimeScale(
            timelineLevel: defaults.startScale
        ).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: defaults.catStyle)
        await persist()

        guard let persisted = try? await repository.load(),
              let reloaded = try? await Self
                .preparedLoadedSnapshotInBackground(persisted) else { return }
        snapshot = reloaded
        selectedScale = TimeScale(
            timelineLevel: reloaded.settings.startScale
        ).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: reloaded.settings.catStyle)
        publishWatchPayload()
    }

    var setupCategories: [CategoryDefinition] {
        snapshot.categories.sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedSetupCategoryCount: Int {
        if !isEditingSetupCategories {
            return snapshot.categories.filter { !$0.isHidden }.count
        }
        return pendingSetupCategoryIDs.count
    }

    func openInitialSetup() {
        let visibleIDs = Set(
            snapshot.categories.filter { !$0.isHidden }.map(\.id)
        )
        pendingSetupCategoryIDs = visibleIDs.isEmpty
            ? Set(snapshot.categories.map(\.id))
            : visibleIDs
        isEditingSetupCategories = true
        detail = .categorySetup
    }

    func toggleSetupCategory(_ categoryID: String) {
        if pendingSetupCategoryIDs.contains(categoryID) {
            pendingSetupCategoryIDs.remove(categoryID)
        } else {
            pendingSetupCategoryIDs.insert(categoryID)
        }
    }

    func cancelInitialCategorySelection() {
        isEditingSetupCategories = false
        pendingSetupCategoryIDs = []
        detail = nil
    }

    func applyInitialCategorySelection() async {
        guard !pendingSetupCategoryIDs.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 하나 이상 선택해 주세요.",
                english: "Select at least one major category."
            )
            return
        }
        snapshot.categories = snapshot.categories.map { category in
            var updated = category
            updated.isHidden = !pendingSetupCategoryIDs.contains(category.id)
            return updated
        }
        await persist()
        isEditingSetupCategories = false
        detail = nil
    }

    /// 메모 입력의 유일한 입구. 계획도 기록도 고르지 않고 순간만 받는다.
    /// `memoIDs` 가 비어 있지 않으면 그 자리에 이미 있던 메모를 펼친다.
    func openMemoEntry(at instant: Date, memoIDs: [UUID] = []) {
        memoEntry = MemoEntry(occurredAt: instant, memoIDs: memoIDs)
        detail = .memo
    }

    func closeMemoEntry() {
        memoEntry = nil
        detail = nil
    }

    /// 메모가 놓일 순간을 옮긴다. 손가락으로만 움직이므로 키보드는 메모 글에만
    /// 쓰인다.
    func moveMemoEntry(to instant: Date) {
        guard memoEntry?.occurredAt != instant else { return }
        memoEntry?.occurredAt = instant
    }

    var memoEntryMemos: [ActionMemo] {
        guard let memoEntry, !memoEntry.memoIDs.isEmpty else { return [] }
        let ids = Set(memoEntry.memoIDs)
        return snapshot.memos
            .filter { ids.contains($0.id) }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    /// 시간표 메모 줄이 읽는 값. 항목에 붙은 메모도 결국 한 순간에 놓이므로
    /// 줄 하나가 그 기간의 메모를 전부 보여 준다.
    func timelineMemos(in span: TimeSpan) -> [ActionMemo] {
        snapshot.memos.filter {
            $0.occurredAt >= span.start && $0.occurredAt < span.end
        }
    }

    @discardableResult
    func addMemoAtEntryInstant(text: String, kind: MemoKind) -> UUID? {
        guard let entry = memoEntry,
              let id = addMemo(
                  text: text,
                  kind: kind,
                  categoryID: MemoTimelineEngine.categoryID,
                  on: entry.occurredAt
              ) else {
            return nil
        }
        memoEntry?.memoIDs.append(id)
        return id
    }

    func addAttachmentMemoAtEntryInstant(
        kind: MemoKind,
        attachmentKind: AttachmentKind,
        localIdentifier: String,
        text: String? = nil
    ) {
        guard acceptsDataMutation() else { return }
        guard let entry = memoEntry else { return }
        let fallbackText = attachmentKind == .photo ? "사진 메모" : "음성 메모"
        guard let memoText = validatedMemoText(text ?? fallbackText) else {
            return
        }
        let memo = ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: entry.occurredAt,
            kind: kind,
            text: memoText,
            attachments: [
                MemoAttachment(
                    kind: attachmentKind,
                    localIdentifier: localIdentifier
                ),
            ]
        )
        snapshot.memos.append(memo)
        memoEntry?.memoIDs.append(memo.id)
        Task { await persist() }
    }

    /// 알람 판정용: 선택한 날짜(오늘)의 센서 측정. 읽지 못하면 빈 배열.
    func readingsForAlarmCheck(on day: Date) async -> [SensorReading] {
        guard let sensorService else { return [] }
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) ?? start
        return (try? await sensorService.archivedReadings(in: TimeSpan(start: start, end: end))) ?? []
    }

    /// 메모(지도·일반 편집 화면)에 음성 파일을 오디오 첨부로 붙인다.
    func attachAudio(toMemo memoID: UUID, localIdentifier: String) {
        guard acceptsDataMutation() else { return }
        guard let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return }
        snapshot.memos[index].attachments.append(
            MemoAttachment(kind: .audio, localIdentifier: localIdentifier)
        )
        Task { await persist() }
    }

    func memos(for planID: UUID?) -> [ActionMemo] {
        guard let planID else { return [] }
        return snapshot.memos
            .filter {
                $0.planID == planID
                    && ($0.targetID == nil
                        || $0.targetID == "plan.\(planID.uuidString)")
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func memos(forTargetID targetID: String?) -> [ActionMemo] {
        guard let targetID, !targetID.isEmpty else { return [] }
        return snapshot.memos
            .filter { $0.targetID == targetID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Notes left on a category row. They belong to the category and the day,
    /// not to a plan, so nothing has to be invented to store them.
    func memos(forCategoryID categoryID: String?, on date: Date) -> [ActionMemo] {
        guard let categoryID, !categoryID.isEmpty else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        return snapshot.memos
            .filter {
                $0.planID == nil
                    && $0.targetID == nil
                    && $0.categoryID == categoryID
                    && calendar.isDate($0.occurredAt, inSameDayAs: date)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addMemo(
        text: String,
        kind: MemoKind,
        to planID: UUID
    ) {
        guard let cleanText = validatedMemoText(text),
              let plan = snapshot.plans.first(where: { $0.id == planID })
        else {
            return
        }
        snapshot.memos.append(
            ActionMemo(
                planID: planID,
                categoryID: plan.categoryID,
                occurredAt: plan.span.start,
                kind: kind,
                text: cleanText
            )
        )
        Task { await persist() }
    }

    @discardableResult
    func addMemo(
        text: String,
        kind: MemoKind,
        categoryID: String,
        on date: Date
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let cleanText = validatedMemoText(text),
              !categoryID.isEmpty else { return nil }
        let memo = ActionMemo(
            categoryID: categoryID,
            occurredAt: date,
            kind: kind,
            text: cleanText
        )
        snapshot.memos.append(memo)
        Task { await persist() }
        return memo.id
    }

    @discardableResult
    func addMapMemo(
        text: String,
        kind: MemoKind,
        mapPoint: GeoPoint,
        planID: UUID? = nil,
        targetID: String? = nil,
        occurredAt: Date,
        shouldPersist: Bool = true
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let cleanText = validatedMemoText(text),
              occurredAt.timeIntervalSince1970.isFinite,
              mapPoint.latitude.isFinite,
              mapPoint.longitude.isFinite,
              mapPoint.altitude.isFinite,
              mapPoint.horizontalAccuracy.isFinite,
              mapPoint.verticalAccuracy.isFinite,
              (-90...90).contains(mapPoint.latitude),
              (-180...180).contains(mapPoint.longitude) else {
            return nil
        }
        let requestedPlan = planID.flatMap { planID in
            snapshot.plans.first(where: { $0.id == planID })
        }
        let linkedPlan = requestedPlan.flatMap { plan in
            plan.span.start <= occurredAt && occurredAt < plan.span.end
                ? plan
                : nil
        } ?? MapMemoLinkEngine.plan(
            containing: occurredAt,
            in: snapshot.plans
        )
        let memo = ActionMemo(
            planID: linkedPlan?.id,
            targetID: targetID,
            categoryID: linkedPlan?.categoryID ?? MemoTimelineEngine.categoryID,
            occurredAt: occurredAt,
            mapPoint: mapPoint,
            kind: kind,
            text: cleanText
        )
        snapshot.memos.append(memo)
        if shouldPersist {
            invalidateReviewArchives(dates: [occurredAt])
            Task { await persist() }
        } else {
            pendingMapMemoIDs.insert(memo.id)
        }
        return memo.id
    }

    /// 통합 메모의 초안: 위치·시간 없이 먼저 만들고, 편집 화면에서 위치·시간을 더한 뒤 저장한다.
    /// 저장 전에는 임시(pending) 상태라 저장소에 쓰지 않는다. 시간은 기본적으로 지정하지 않음.
    func addMemoDraft(
        text: String,
        occurredAt: Date = .now,
        mapPoint: GeoPoint? = nil,
        isTimeless: Bool = true
    ) -> UUID? {
        guard acceptsDataMutation(), let cleanText = validatedMemoText(text) else { return nil }
        let memo = ActionMemo(
            planID: nil,
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: occurredAt,
            mapPoint: mapPoint,
            isTimeless: isTimeless,
            kind: .idea,
            text: cleanText
        )
        snapshot.memos.append(memo)
        pendingMapMemoIDs.insert(memo.id)
        return memo.id
    }

    /// 임시 메모 초안을 저장소에 쓰지 않고 바꾼다(위치를 고르러 편집 화면을 닫을 때 쓴다).
    /// 글자가 비어 있으면 이전 글자를 그대로 둔다.
    func updateMemoDraft(
        _ memoID: UUID,
        text: String?,
        occurredAt: Date?,
        isTimeless: Bool?,
        mapPoint: GeoPoint??
    ) {
        guard pendingMapMemoIDs.contains(memoID),
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return }
        if let text {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean.count <= 1_000 { snapshot.memos[index].text = clean }
        }
        if let occurredAt, occurredAt.timeIntervalSince1970.isFinite {
            snapshot.memos[index].occurredAt = occurredAt
        }
        if let isTimeless { snapshot.memos[index].isTimeless = isTimeless ? true : nil }
        if let mapPoint { snapshot.memos[index].mapPoint = mapPoint }
    }

    func isMemoDraft(_ memoID: UUID) -> Bool { pendingMapMemoIDs.contains(memoID) }

    func discardMapMemoDraft(_ memoID: UUID) {
        guard acceptsDataMutation() else { return }
        guard snapshot.memos.contains(where: { memo in
            memo.id == memoID && (memo.mapPoint != nil || pendingMapMemoIDs.contains(memoID))
        }) else {
            return
        }
        pendingMapMemoIDs.remove(memoID)
        snapshot.memos.removeAll { $0.id == memoID }
        memoEntry?.memoIDs.removeAll { $0 == memoID }
    }

    func deleteMemo(_ memoID: UUID) {
        guard let memo = snapshot.memos.first(where: { $0.id == memoID }) else {
            return
        }
        if pendingMapMemoIDs.remove(memoID) != nil {
            snapshot.memos.removeAll { $0.id == memoID }
            memoEntry?.memoIDs.removeAll { $0 == memoID }
            return
        }
        invalidateReviewArchives(dates: [memo.occurredAt])
        snapshot.settings.cloudDeletedRecordKeys.insert(
            CloudBackupRecordKey.memo(memoID)
        )
        snapshot.memos.removeAll { $0.id == memoID }
        memoEntry?.memoIDs.removeAll { $0 == memoID }
        Task { await persist() }
    }

    func updateMemo(
        _ memoID: UUID,
        text: String,
        kind: MemoKind
    ) {
        guard let cleanText = validatedMemoText(text),
              let index = snapshot.memos.firstIndex(where: {
            $0.id == memoID
        }), let updated = ActionMemoEditingEngine.updating(
            snapshot.memos[index],
            text: cleanText,
            kind: kind
        ) else {
            return
        }
        snapshot.memos[index] = updated
        Task { await persist() }
    }

    @discardableResult
    func updateMapMemo(
        _ memoID: UUID,
        text: String,
        kind: MemoKind,
        mapPoint: GeoPoint?,
        occurredAt: Date,
        isTimeless: Bool = false
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        guard let cleanText = validatedMemoText(text),
              occurredAt.timeIntervalSince1970.isFinite,
              mapPoint.map({ point in
                  point.latitude.isFinite
                      && point.longitude.isFinite
                      && point.altitude.isFinite
                      && point.horizontalAccuracy.isFinite
                      && point.verticalAccuracy.isFinite
                      && (-90...90).contains(point.latitude)
                      && (-180...180).contains(point.longitude)
              }) ?? true,
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }),
              let updated = ActionMemoEditingEngine.updating(
                  snapshot.memos[index],
                  text: cleanText,
                  kind: kind
              ) else {
            return false
        }
        let previousDate = snapshot.memos[index].occurredAt
        let existingMemo = snapshot.memos[index]
        var value = updated
        let linkedPlan = MapMemoLinkEngine.plan(
            containing: occurredAt,
            in: snapshot.plans
        )
        value.planID = isTimeless ? nil : linkedPlan?.id
        value.categoryID = isTimeless ? (existingMemo.categoryID ?? MemoTimelineEngine.categoryID) : (linkedPlan?.categoryID
            ?? (existingMemo.planID == nil
                ? (existingMemo.categoryID ?? MemoTimelineEngine.categoryID)
                : MemoTimelineEngine.categoryID))
        value.mapPoint = mapPoint
        value.isTimeless = isTimeless ? true : nil
        value.occurredAt = occurredAt
        snapshot.memos[index] = value
        pendingMapMemoIDs.remove(memoID)
        invalidateReviewArchives(dates: [previousDate, occurredAt])
        Task { await persist() }
        return true
    }

    private func validatedMemoText(_ text: String) -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        do {
            try TaptionPlanMemoRecord.validate(text: cleanText)
            return cleanText
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "메모는 1,000자까지 저장할 수 있습니다.",
                english: "Memos can contain up to 1,000 characters."
            )
            return nil
        }
    }

    /// 음성 메모도 붙일 항목을 찾지 않는다. 메모 입력이 열려 있으면 그 순간에
    /// 놓인다.
    func toggleVoiceMemo(kind: MemoKind) async {
        guard memoEntry != nil else { return }

        if isRecordingVoiceMemo {
            guard let url = voiceMemoRecorder.stop() else {
                isRecordingVoiceMemo = false
                return
            }
            isRecordingVoiceMemo = false
            addAttachmentMemoAtEntryInstant(
                kind: kind,
                attachmentKind: .audio,
                localIdentifier: url.path
            )
            return
        }

        voiceMemoPlayer.stop()
        playingVoiceAttachmentID = nil
        let granted = await voiceMemoRecorder.requestPermission()
        snapshot.settings.permissions[.microphone] =
            granted ? .authorized : .denied
        guard granted else {
            userFacingError = AppLanguagePreference.text(
                korean: "음성 메모를 사용하려면 마이크 권한이 필요합니다.",
                english: "Microphone access is required to use voice memos."
            )
            await persist()
            return
        }

        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            _ = try voiceMemoRecorder.start(
                in: root.appendingPathComponent(
                    "TaptionPlan/VoiceMemos",
                    isDirectory: true
                )
            )
            isRecordingVoiceMemo = true
            await persist()
        } catch {
            isRecordingVoiceMemo = false
            let reason = (error as? VoiceMemoRecordingError)?.localizedDescription
                ?? AppLanguagePreference.text(
                    korean: "마이크 입력 장치를 확인해 주세요.",
                    english: "Check your microphone input device."
                )
            userFacingError = AppLanguagePreference.text(
                korean: "음성 녹음을 시작하지 못했습니다. \(reason)",
                english: "Could not start voice recording. \(reason)"
            )
        }
    }

    func toggleVoicePlayback(_ attachment: MemoAttachment) {
        guard attachment.kind == .audio else { return }
        if playingVoiceAttachmentID == attachment.id {
            voiceMemoPlayer.stop()
            playingVoiceAttachmentID = nil
            return
        }
        do {
            try voiceMemoPlayer.play(
                filePath: attachment.localIdentifier
            )
            playingVoiceAttachmentID = attachment.id
        } catch {
            playingVoiceAttachmentID = nil
            userFacingError = AppLanguagePreference.text(
                korean: "음성 메모를 재생하지 못했습니다. \(error.localizedDescription)",
                english: "Could not play the voice memo. \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func addPlan(
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        startAt: Date,
        duration: TimeInterval,
        parentID: UUID? = nil,
        repeatRules: [GoalRepeatRule]? = nil
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, duration > 0 else { return nil }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)
        var plan: PlanRecord
        if let parentID,
           let parent = snapshot.plans.first(where: { $0.id == parentID }) {
            let childDuration = min(duration, parent.span.duration)
            let latestStart = parent.span.end.addingTimeInterval(-childDuration)
            let adjustedStart = min(
                max(startAt, parent.span.start),
                latestStart
            )
            do {
                plan = try GoalDecompositionEngine.makeChild(
                    parent: parent,
                    title: cleanTitle,
                    span: TimeSpan(
                        start: adjustedStart,
                        end: adjustedStart.addingTimeInterval(childDuration)
                    ),
                    categoryID: categoryID
                )
                plan.repeatRules = cleanedRepeatRules
                plan.middleCategoryName = Self.cleanHierarchyName(
                    middleCategoryName
                )
                plan.subCategoryName = Self.cleanHierarchyName(
                    subCategoryName
                )
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "상위 루틴 안에 계획을 배치하지 못했습니다.",
                    english: "Could not place the plan inside the parent routine."
                )
                return nil
            }
        } else {
            plan = PlanRecord(
                title: cleanTitle,
                span: TimeSpan(
                    start: startAt,
                    end: startAt.addingTimeInterval(duration)
                ),
                categoryID: categoryID,
                middleCategoryName: Self.cleanHierarchyName(
                    middleCategoryName
                ),
                subCategoryName: Self.cleanHierarchyName(subCategoryName),
                repeatRules: cleanedRepeatRules
            )
        }
        let previous = snapshot
        snapshot.plans.append(plan)
        if plan.parentID == nil,
           let rules = plan.repeatRules {
            snapshot.plans.append(
                contentsOf: repeatActionItems(for: plan, rules: rules)
            )
        }
        snapshot.plans.sort { $0.span.start < $1.span.start }
        recordUserEdit(from: previous)
        Task { await persist() }
        return plan.id
    }

    private static func cleanHierarchyName(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    func updatePlan(
        _ planID: UUID,
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        span: TimeSpan,
        parentID: UUID?,
        isImportant: Bool,
        repeatRules: [GoalRepeatRule]? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "수정할 계획을 찾지 못했습니다.",
                english: "Could not find the plan to edit."
            )
            return
        }
        guard !snapshot.plans[index].isFixed else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더 고정 일정은 캘린더에서 수정해 주세요.",
                english: "Edit fixed calendar events in the Calendar app."
            )
            return
        }
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanTitle.isEmpty, span.duration > 0 else {
            userFacingError = AppLanguagePreference.text(
                korean: "계획 이름과 시간을 확인해 주세요.",
                english: "Check the plan name and time."
            )
            return
        }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)

        var updated = snapshot.plans[index]
        updated.title = cleanTitle
        updated.categoryID = categoryID
        updated.middleCategoryName = Self.cleanHierarchyName(
            middleCategoryName
        )
        updated.subCategoryName = Self.cleanHierarchyName(subCategoryName)
        updated.span = span
        updated.parentID = parentID
        updated.isImportant = isImportant
        updated.repeatRules = cleanedRepeatRules
        updated.updatedAt = .now

        var candidate = snapshot.plans
        candidate[index] = updated
        candidate.removeAll {
            $0.parentID == planID && $0.origin == .repeatRule
        }
        do {
            try PlanHierarchy.validate(candidate)
            if let parentID,
               let parent = candidate.first(where: {
                   $0.id == parentID
               }),
               (span.start < parent.span.start
                   || span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(
                of: planID,
                in: candidate
            )
            guard children.allSatisfy({
                span.start <= $0.span.start && $0.span.end <= span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            if parentID == nil,
               Self.isGoalTitle(cleanTitle),
               let rules = cleanedRepeatRules {
                candidate.append(
                    contentsOf: repeatActionItems(for: updated, rules: rules)
                )
                try PlanHierarchy.validate(candidate)
            }
            let previous = snapshot
            snapshot.plans = candidate.sorted {
                $0.span.start < $1.span.start
            }
            recordUserEdit(from: previous)
            Task { await persist() }
        } catch PlanningError.parentCycle {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 자기 하위 루틴 안으로 옮길 수 없습니다.",
                english: "A plan cannot be moved inside its own sub-routine."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "상위·하위 계획의 기간 안에서 시간을 정해 주세요.",
                english: "Choose a time within the period of the parent and child plans."
            )
        }
    }

    /// Attach an existing action item to a routine without creating a
    /// duplicate plan. Re-selecting a routine moves an already grouped action
    /// after validating the new parent, so the detail tab can expose a single
    /// "루틴 연결/변경" action.
    func connectActionItem(
        _ planID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let planIndex = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }), let target = snapshot.plans.first(where: { $0.id == goalID }),
              GoalRecordPolicy.isGoal(target) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 루틴 또는 액션아이템을 찾지 못했습니다.",
                english: "Could not find the routine or action item to link."
            )
            return
        }
        let plan = snapshot.plans[planIndex]
        guard plan.origin != .repeatRule,
              !GoalRecordPolicy.isGoal(plan),
              !AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                  plan.categoryID
              ) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 루틴은 액션아이템으로 연결할 수 없습니다.",
                english: "Repeating segments and routines cannot be linked as action items."
            )
            return
        }
        do {
            var candidatePlans = snapshot.plans
            if let planIndex = candidatePlans.firstIndex(where: { $0.id == planID }) {
                // Clear the old parent first. PlanHierarchy.attach then
                // validates the same action against the new routine's span.
                candidatePlans[planIndex].parentID = nil
            }
            let attached = try PlanHierarchy.attach(
                child: candidatePlans[planIndex],
                to: goalID,
                in: candidatePlans
            )
            candidatePlans[planIndex] = attached
            try PlanHierarchy.validate(candidatePlans)
            snapshot.plans = candidatePlans
            snapshot.plans.sort { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            await persist()
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "액션아이템의 시간이 루틴 기간 안에 있어야 합니다.",
                english: "The action item's time must fall within the routine's period."
            )
        } catch PlanningError.parentCycle {
            userFacingError = AppLanguagePreference.text(
                korean: "루틴의 하위 항목을 다시 연결할 수 없습니다.",
                english: "A routine's sub-items cannot be relinked."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "액션아이템을 루틴에 연결하지 못했습니다.",
                english: "Could not link the action item to the routine."
            )
        }
    }

    /// Attach an existing activity/actual record to a goal. This is a
    /// lightweight evidence link; it deliberately does not move the record
    /// or create a hierarchy child plan.
    func connectActualRecord(
        _ actualID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let actualIndex = snapshot.actuals.firstIndex(where: {
            $0.id == actualID
        }), let goal = snapshot.plans.first(where: {
            $0.id == goalID && !$0.isFixed && $0.status != .skipped
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 실제 기록 또는 루틴을 찾지 못했습니다.",
                english: "Could not find the actual record or routine to link."
            )
            return
        }

        let actual = snapshot.actuals[actualIndex]
        guard actual.span().intersection(with: goal.span) != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "실제 기록 시간이 루틴 기간 안에 있어야 합니다.",
                english: "The actual record's time must fall within the routine's period."
            )
            return
        }

        guard GoalRecordPolicy.isGoal(goal)
                || (goal.origin != .repeatRule && goal.origin != .calendar) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다.",
                english: "Repeating segments and events cannot be used as link targets."
            )
            return
        }

        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
                || GoalRecordPolicy.isGoal(goal) else {
            userFacingError = AppLanguagePreference.text(
                korean: "수면·활동 기록은 루틴에만 연결할 수 있습니다.",
                english: "Sleep and activity records can only be linked to routines."
            )
            return
        }

        var updated = actual
        if GoalRecordPolicy.isGoal(goal) {
            updated.routineID = goal.id
            updated.planID = nil
        } else {
            updated.planID = goal.id
            updated.routineID = routineAncestorID(
                for: goal.id
            )
        }
        guard let edit = PlanActualEdit(replacing: updated, at: actualIndex, in: snapshot.actuals) else { return }
        let normalizationWasPending = needsLocalRecordNormalization
        snapshot.actuals = edit.result
        // Linking does not alter classification or require another historical normalization.
        needsLocalRecordNormalization = normalizationWasPending
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
        }
        await persist(actualEdit: edit)
    }

    /// Create a relationship only after the user explicitly taps the source
    /// record and chooses a routine/action. Activity records use their typed
    /// fields so routine progress can count them; location/travel/calendar
    /// records are retained as generic graph links.
    func connectRecordNode(
        _ sourceNodeID: String,
        to planID: UUID
    ) async {
        guard let target = snapshot.plans.first(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 루틴 또는 액션아이템을 찾지 못했습니다.",
                english: "Could not find the routine or action item to link."
            )
            return
        }
        guard GoalRecordPolicy.isGoal(target)
                || (target.origin != .repeatRule && target.origin != .calendar) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다.",
                english: "Repeating segments and events cannot be used as link targets."
            )
            return
        }
        let targetNodeID = "\(GoalRecordPolicy.isGoal(target) ? "routine" : "action").\(planID.uuidString)"
        guard sourceNodeID != targetNodeID else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 항목에는 연결할 수 없습니다.",
                english: "An item cannot be linked to itself."
            )
            return
        }

        if sourceNodeID.hasPrefix("automatic.actual."),
           let actualID = UUID(
               uuidString: String(sourceNodeID.dropFirst("automatic.actual.".count))
           ), let actualIndex = snapshot.actuals.firstIndex(where: {
               $0.id == actualID
           }) {
            guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(
                snapshot.actuals[actualIndex]
            ) || GoalRecordPolicy.isGoal(target) else {
                userFacingError = AppLanguagePreference.text(
                    korean: "수면·활동 기록은 루틴에만 연결할 수 있습니다.",
                    english: "Sleep and activity records can only be linked to routines."
                )
                return
            }
            if GoalRecordPolicy.isGoal(target) {
                snapshot.actuals[actualIndex].routineID = planID
                snapshot.actuals[actualIndex].planID = nil
            } else {
                snapshot.actuals[actualIndex].planID = planID
                snapshot.actuals[actualIndex].routineID = routineAncestorID(
                    for: planID
                )
            }
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
        } else {
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
            snapshot.recordLinks.append(
                RecordLink(fromNodeID: sourceNodeID, toNodeID: targetNodeID)
            )
        }
        await persist()
    }

    /// Save the portion of a routine that was actually performed.  The
    /// interval is deliberately kept as a separate ActualRecord so the
    /// planned block remains intact and the dashboard can distinguish a full
    /// completion from a partial run.
    func updateRoutineActualInterval(
        planID: UUID,
        actualID: UUID? = nil,
        startedAt: Date,
        endedAt: Date?
    ) async {
        guard acceptsDataMutation() else { return }
        guard let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "루틴을 찾지 못했습니다.",
                english: "Could not find the routine."
            )
            return
        }
        let minimumEnd = startedAt.addingTimeInterval(60)
        let normalizedEnd = endedAt.map { max(minimumEnd, $0) }
        let existingIndex = actualID.flatMap { id in
            snapshot.actuals.firstIndex(where: { $0.id == id })
        } ?? snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.source == .manual
        })
        let routineID = routineAncestorID(for: planID)

        if let actualIndex = existingIndex {
            snapshot.actuals[actualIndex].planID = planID
            snapshot.actuals[actualIndex].routineID = routineID
            snapshot.actuals[actualIndex].startedAt = startedAt
            snapshot.actuals[actualIndex].endedAt = normalizedEnd
            snapshot.actuals[actualIndex].title = snapshot.plans[planIndex].title
            snapshot.actuals[actualIndex].categoryID = snapshot.plans[planIndex].categoryID
        } else {
            snapshot.actuals.append(
                ActualRecord(
                    planID: planID,
                    routineID: routineID,
                    title: snapshot.plans[planIndex].title,
                    categoryID: snapshot.plans[planIndex].categoryID,
                    startedAt: startedAt,
                    endedAt: normalizedEnd,
                    source: .manual,
                    confidence: .high
                )
            )
        }

        let performed = normalizedEnd.map {
            max(0, $0.timeIntervalSince(startedAt))
        } ?? 0
        let planned = snapshot.plans[planIndex].span.duration
        if planned > 0, performed >= planned * 0.999 {
            snapshot.plans[planIndex].status = .completed
        } else if snapshot.plans[planIndex].status == .completed {
            snapshot.plans[planIndex].status = .planned
        }
        snapshot.plans[planIndex].updatedAt = .now
        await persist()
    }

    private func routineAncestorID(for planID: UUID) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = snapshot.plans.first(where: { $0.id == id }) {
            if GoalRecordPolicy.isGoal(plan) { return plan.id }
            currentID = plan.parentID
        }
        return nil
    }

    private static func cleanGoalRepeatRules(
        _ rules: [GoalRepeatRule]?
    ) -> [GoalRepeatRule]? {
        let cleaned = (rules ?? []).compactMap { rule -> GoalRepeatRule? in
            let weekdays = Set(rule.weekdays.filter { (1...7).contains($0) })
            guard !weekdays.isEmpty else { return nil }
            var value = rule
            value.name = Self.cleanHierarchyName(rule.name)
            value.weekdays = weekdays
            value.startMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.startMinuteOfDay)
            )
            value.endMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.endMinuteOfDay)
            )
            return value
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isGoalTitle(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.hasPrefix(GoalRecordPolicy.currentPrefix)
            || clean.hasPrefix(GoalRecordPolicy.legacyPrefix)
    }

    private func repeatActionItems(
        for goal: PlanRecord,
        rules: [GoalRepeatRule],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PlanRecord] {
        guard !rules.isEmpty, goal.span.duration >= 60 else { return [] }

        let goalName = cleanGoalDisplayName(goal.title)
        let middleName = Self.cleanHierarchyName(goal.middleCategoryName)
            ?? goalName
        var cursor = calendar.startOfDay(for: goal.span.start)
        let lastDay = calendar.startOfDay(for: goal.span.end)
        var values: [PlanRecord] = []
        var safetyCounter = 0

        while cursor <= lastDay, safetyCounter < 5_000 {
            safetyCounter += 1
            let weekday = calendar.component(.weekday, from: cursor)
            for rule in rules where rule.weekdays.contains(weekday) {
                guard let rawStart = calendar.date(
                    byAdding: .minute,
                    value: rule.startMinuteOfDay,
                    to: cursor
                ) else {
                    continue
                }
                let endBase: Date
                if rule.endMinuteOfDay <= rule.startMinuteOfDay {
                    endBase = calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: cursor
                    ) ?? cursor.addingTimeInterval(86_400)
                } else {
                    endBase = cursor
                }
                guard let rawEnd = calendar.date(
                    byAdding: .minute,
                    value: rule.endMinuteOfDay,
                    to: endBase
                ) else {
                    continue
                }

                let start = max(rawStart, goal.span.start)
                let end = min(rawEnd, goal.span.end)
                guard end.timeIntervalSince(start) >= 60 else {
                    continue
                }

                values.append(
                    PlanRecord(
                        title: repeatActionTitle(
                            goalName: goalName,
                            rule: rule
                        ),
                        span: TimeSpan(start: start, end: end),
                        categoryID: goal.categoryID,
                        middleCategoryName: middleName,
                        subCategoryName: repeatRuleDisplayName(rule),
                        parentID: goal.id,
                        origin: .repeatRule
                    )
                )
            }

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: cursor
            ) else {
                break
            }
            cursor = nextDay
        }

        return values.sorted { $0.span.start < $1.span.start }
    }

    private func cleanGoalDisplayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmed.hasPrefix(GoalRecordPolicy.currentPrefix) {
            prefix = GoalRecordPolicy.currentPrefix
        } else if trimmed.hasPrefix(GoalRecordPolicy.legacyPrefix) {
            prefix = GoalRecordPolicy.legacyPrefix
        } else {
            return trimmed
        }
        let clean = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? trimmed : String(clean)
    }

    private func repeatActionTitle(
        goalName: String,
        rule: GoalRepeatRule
    ) -> String {
        guard let ruleName = repeatRuleDisplayName(rule),
              !ruleName.isEmpty,
              ruleName != goalName else {
            return goalName
        }
        return "\(goalName) · \(ruleName)"
    }

    private func repeatRuleDisplayName(_ rule: GoalRepeatRule) -> String? {
        let clean = Self.cleanHierarchyName(rule.name)
        return clean ?? Self.repeatWeekdayText(rule.weekdays)
    }

    private static func repeatWeekdayText(_ weekdays: Set<Int>) -> String {
        let normalized = Set(weekdays.filter { (1...7).contains($0) })
        if normalized == [1, 2, 3, 4, 5, 6, 7] {
            return AppLanguagePreference.text(korean: "매일", english: "Daily")
        }
        if normalized == [2, 3, 4, 5, 6] {
            return AppLanguagePreference.text(korean: "주중", english: "Weekdays")
        }
        if normalized == [1, 7] {
            return AppLanguagePreference.text(korean: "주말", english: "Weekends")
        }
        // Index 0 is Sunday to match `Calendar` weekday numbers (1...7).
        let labels = AppLanguagePreference.text(
            korean: "일,월,화,수,목,금,토",
            english: "Sun,Mon,Tue,Wed,Thu,Fri,Sat"
        ).split(separator: ",").map(String.init)
        return [2, 3, 4, 5, 6, 7, 1]
            .filter { normalized.contains($0) }
            .map { labels[$0 - 1] }
            .joined(separator: AppLanguagePreference.text(korean: "·", english: ", "))
    }

    func deletePlan(_ planID: UUID) async {
        guard let plan = snapshot.plans.first(where: {
            $0.id == planID
        }) else {
            return
        }
        clearUserEditRedoHistory()
        let descendants = (try? PlanHierarchy.descendants(
            of: planID,
            in: snapshot.plans
        )) ?? []
        let deletedIDs = Set([planID] + descendants.map(\.id))
        invalidateReviewArchives(
            spans: ([plan] + descendants).map(\.span),
            dates: snapshot.memos.compactMap { memo in
                memo.planID.map(deletedIDs.contains) == true
                    ? memo.occurredAt
                    : nil
            }
        )
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            deletedIDs.map(CloudBackupRecordKey.plan)
        )
        snapshot.plans.removeAll { deletedIDs.contains($0.id) }
        snapshot.memos = snapshot.memos.map { memo in
            var detached = memo
            if let planID = memo.planID, deletedIDs.contains(planID) {
                detached.planID = nil
            }
            if let targetID = memo.targetID,
               targetID.hasPrefix("plan."),
               let targetPlanID = UUID(
                   uuidString: String(targetID.dropFirst("plan.".count))
               ),
               deletedIDs.contains(targetPlanID) {
                detached.targetID = nil
            }
            return detached
        }
        snapshot.actuals = snapshot.actuals.map { actual in
            guard actual.planID.map(deletedIDs.contains) == true
                || actual.routineID.map(deletedIDs.contains) == true else {
                return actual
            }
            var preserved = actual
            if preserved.planID.map(deletedIDs.contains) == true {
                preserved.planID = nil
            }
            if preserved.routineID.map(deletedIDs.contains) == true {
                preserved.routineID = nil
            }
            return preserved
        }
        removeRecordLinks { link in
            recordNodePlanID(link.fromNodeID).map(deletedIDs.contains) == true
                || recordNodePlanID(link.toNodeID).map(deletedIDs.contains) == true
        }
        selectedGroupPlanID = nil
        groupNavigationPath.removeAll {
            deletedIDs.contains($0)
        }
        let majorCategory = currentMajorCategory(for: plan)
        try? await liveActivityController.stop(
            plan: plan,
            catStyle: snapshot.settings.catStyle,
            majorCategoryID: majorCategory.id,
            majorCategoryTitle: majorCategory.title,
            majorCategorySystemImage: majorCategory.systemImage
        )
        await persist()
    }

    private func recordNodePlanID(_ nodeID: String) -> UUID? {
        for prefix in ["routine.", "action."] where nodeID.hasPrefix(prefix) {
            return UUID(uuidString: String(nodeID.dropFirst(prefix.count)))
        }
        return nil
    }

    private func removeRecordLinks(
        where shouldRemove: (RecordLink) -> Bool
    ) {
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            snapshot.recordLinks.lazy
                .filter(shouldRemove)
                .map { CloudBackupRecordKey.link($0.id) }
        )
        snapshot.recordLinks.removeAll(where: shouldRemove)
    }

    private func currentMajorCategory(for plan: PlanRecord) -> (
        id: String,
        title: String,
        systemImage: String
    ) {
        let storedTitle = snapshot.categories.first(where: {
            $0.id == plan.categoryID
        })?.name
            ?? TimelineRowKind.title(forCategoryID: plan.categoryID)
            ?? AppLanguagePreference.text(korean: "활동", english: "Activity")
        let title: String = switch plan.categoryID {
        case "activity": AppLanguagePreference.text(korean: "활동", english: "Activity")
        case "work": AppLanguagePreference.text(korean: "업무", english: "Work")
        case "study": AppLanguagePreference.text(korean: "수업", english: "Study")
        case "hobby": AppLanguagePreference.text(korean: "취미", english: "Hobby")
        case "sleep": AppLanguagePreference.text(korean: "수면", english: "Sleep")
        case "movement": AppLanguagePreference.text(korean: "이동", english: "Movement")
        case "eating": AppLanguagePreference.text(korean: "식사", english: "Eating")
        case "exercise": AppLanguagePreference.text(korean: "운동", english: "Exercise")
        case "unconfirmed": AppLanguagePreference.text(korean: "미확인", english: "Unconfirmed")
        default: storedTitle
        }
        let systemImage = RecordClassificationCatalog.categories.first {
            $0.id == plan.categoryID
        }?.systemImage ?? TimelineRowKind(categoryID: plan.categoryID)?.systemImage
            ?? "sparkles"
        return (plan.categoryID, title, systemImage)
    }

    private func currentLiveActivityProjection(at date: Date = .now) -> (
        title: String,
        categoryID: String,
        systemImage: String
    ) {
        if !TaptionExternalPrivacyStore.isLocked,
           let categoryID = TaptionCurrentActivityPolicy.categoryID(
            actuals: snapshot.actuals,
            plans: snapshot.plans,
            at: date,
            latestSavedAt: lastSensorSavedAt,
            latestReading: latestSensorReading
        ) {
            let systemImage = RecordClassificationCatalog.categories.first {
                $0.id == categoryID
            }?.systemImage ?? TimelineRowKind(categoryID: categoryID)?.systemImage
                ?? "sparkles"
            let title = RecordClassificationCatalog.categories.first {
                $0.id == categoryID
            }?.title ?? TimelineRowKind.title(forCategoryID: categoryID)
                ?? AppLanguagePreference.text(korean: "활동", english: "Activity")
            return (title, categoryID, systemImage)
        }
        return (
            AppLanguagePreference.text(korean: "확인 중", english: "Checking"),
            "unconfirmed",
            "questionmark"
        )
    }

    func deleteActual(_ actualID: UUID) async {
        guard acceptsDataMutation() else { return }
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "삭제할 실제 기록을 찾지 못했습니다.",
                english: "Could not find the actual record to delete."
            )
            return
        }

        clearUserEditRedoHistory()
        invalidateReviewArchives(spans: [actual.span()])
        snapshot.settings.suppressedActualIDs.insert(actualID)
        snapshot.actuals.removeAll { $0.id == actualID }
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
                || $0.toNodeID == "automatic.actual.\(actualID.uuidString)"
        }

        if actual.endedAt == nil,
           let planID = actual.planID,
           let planIndex = snapshot.plans.firstIndex(where: {
               $0.id == planID
           }),
           snapshot.plans[planIndex].status == .running {
            snapshot.plans[planIndex].status = .planned
            snapshot.plans[planIndex].updatedAt = .now
            let majorCategory = currentMajorCategory(for: snapshot.plans[planIndex])
            try? await liveActivityController.stop(
                plan: snapshot.plans[planIndex],
                catStyle: snapshot.settings.catStyle,
                majorCategoryID: majorCategory.id,
                majorCategoryTitle: majorCategory.title,
                majorCategorySystemImage: majorCategory.systemImage
            )
        }

        await persist()
    }

    func addPlanToCalendar(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더로 보낼 계획을 찾지 못했습니다.",
                english: "Could not find the plan to send to Calendar."
            )
            return
        }
        if snapshot.plans[index].externalEventID != nil {
            return
        }
        if !permissionState(for: .calendar).isGranted {
            await requestCalendar()
        }
        guard permissionState(for: .calendar).isGranted else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더 권한을 허용해 주세요.",
                english: "Please allow Calendar access."
            )
            return
        }
        do {
            let calendarID = snapshot.settings.selectedCalendarIDs.first
            let eventID = try calendarService.addPlan(
                snapshot.plans[index],
                to: calendarID
            )
            snapshot.plans[index].externalCalendarID = calendarID
            snapshot.plans[index].externalEventID = eventID
            snapshot.plans[index].updatedAt = .now
            await refreshCalendarEvents()
            await persist()
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 캘린더에 추가하지 못했습니다. \(error.localizedDescription)",
                english: "Could not add the plan to Calendar. \(error.localizedDescription)"
            )
        }
    }

    func movePlan(_ planID: UUID, by delta: TimeInterval) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        do {
            let moved = try ScheduleEditEngine.move(
                snapshot.plans[index],
                by: delta
            )
            if let parentID = moved.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (moved.span.start < parent.span.start
                   || moved.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }

            let descendants = try PlanHierarchy.descendants(
                of: planID,
                in: snapshot.plans
            )
            let appliedDelta = moved.span.start.timeIntervalSince(
                snapshot.plans[index].span.start
            )
            let previous = snapshot
            snapshot.plans[index] = moved
            for descendant in descendants {
                guard let childIndex = snapshot.plans.firstIndex(where: {
                    $0.id == descendant.id
                }) else {
                    continue
                }
                snapshot.plans[childIndex] = try ScheduleEditEngine.move(
                    descendant,
                    by: appliedDelta
                )
            }
            snapshot.plans.sort { $0.span.start < $1.span.start }
            recordUserEdit(
                from: previous,
                coalescingKey: "plan:\(planID.uuidString)"
            )
            Task { await persist() }
        } catch PlanningError.fixedPlan {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더의 고정 일정은 이곳에서 옮길 수 없습니다.",
                english: "Fixed calendar events cannot be moved here."
            )
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "하위 계획은 상위 루틴 기간 안에서만 옮길 수 있습니다.",
                english: "A sub-plan can only be moved within its parent routine's period."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 옮기지 못했습니다.",
                english: "Could not move the plan."
            )
        }
    }

    func resizePlan(
        _ planID: UUID,
        startDelta: TimeInterval? = nil,
        endDelta: TimeInterval? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        let plan = snapshot.plans[index]
        do {
            let resized = try ScheduleEditEngine.resize(
                plan,
                newStart: startDelta.map {
                    plan.span.start.addingTimeInterval($0)
                },
                newEnd: endDelta.map {
                    plan.span.end.addingTimeInterval($0)
                }
            )
            if let parentID = resized.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (resized.span.start < parent.span.start
                   || resized.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(of: planID, in: snapshot.plans)
            guard children.allSatisfy({
                resized.span.start <= $0.span.start
                    && $0.span.end <= resized.span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            let previous = snapshot
            snapshot.plans[index] = resized
            recordUserEdit(
                from: previous,
                coalescingKey: "plan:\(planID.uuidString)"
            )
            Task { await persist() }
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "상위·하위 계획의 기간을 벗어나지 않도록 길이를 조절해 주세요.",
                english: "Adjust the length so it stays within the period of the parent and child plans."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획 길이를 조절하지 못했습니다.",
                english: "Could not adjust the plan length."
            )
        }
    }

    @discardableResult
    func addCustomCategory(
        name: String,
        icon: CategoryIcon,
        lightHex: String
    ) -> CategoryDefinition? {
        guard acceptsDataMutation() else { return nil }
        do {
            let category = try CategoryCatalog.makeCustom(
                name: name,
                icon: icon,
                lightHex: lightHex,
                existing: snapshot.categories
            )
            snapshot.categories.append(category)
            snapshot.categories.sort { $0.sortOrder < $1.sortOrder }
            Task { await persist() }
            return category
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 추가하지 못했습니다. \(error.localizedDescription)",
                english: "Could not add the major category. \(error.localizedDescription)"
            )
            return nil
        }
    }

    func updateCategory(
        _ categoryID: String,
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        hidden: Bool
    ) {
        guard let index = snapshot.categories.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !snapshot.categories.contains(where: {
            $0.id != categoryID
                && $0.name.localizedCaseInsensitiveCompare(cleanName)
                    == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 대분류가 이미 있습니다.",
                english: "A major category with the same name already exists."
            )
            return
        }
        do {
            snapshot.categories[index] = try CategoryCatalog.update(
                snapshot.categories[index],
                name: cleanName,
                icon: icon,
                lightHex: lightHex,
                hidden: hidden
            )
            Task { await persist() }
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 수정하지 못했습니다. \(error.localizedDescription)",
                english: "Could not edit the major category. \(error.localizedDescription)"
            )
        }
    }

    func moveCategory(_ categoryID: String, by offset: Int) {
        let sorted = snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        guard let index = sorted.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let destination = index + offset
        guard sorted.indices.contains(destination) else { return }
        var orderedIDs = sorted.map(\.id)
        orderedIDs.swapAt(index, destination)
        applyCategoryOrder(orderedIDs)
    }

    func moveCategories(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        snapshot.categories = CategoryCatalog.moving(
            snapshot.categories,
            fromOffsets: source,
            toOffset: destination
        )
        Task { await persist() }
    }

    private func applyCategoryOrder(_ orderedIDs: [String]) {
        snapshot.categories = CategoryCatalog.reordered(
            snapshot.categories,
            orderedIDs: orderedIDs
        )
        Task { await persist() }
    }

    func setTimelineRowOrder(_ orderedIDs: [String]) {
        let normalized = AppFeatureSettings.normalizedTimelineRowOrder(
            orderedIDs
        )
        guard snapshot.settings.timelineRowOrder != normalized else {
            return
        }
        snapshot.settings.timelineRowOrder = normalized
        Task { await persist() }
    }

    func deleteCustomCategory(
        _ categoryID: String,
        reassigningTo replacementID: String
    ) {
        do {
            let result = try CategoryCatalog.deleting(
                categoryID: categoryID,
                reassigningTo: replacementID,
                categories: snapshot.categories,
                plans: snapshot.plans,
                actuals: snapshot.actuals
            )
            snapshot.categories = result.categories
            snapshot.plans = result.plans
            snapshot.actuals = result.actuals
            Task { await persist() }
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 삭제하지 못했습니다. \(error.localizedDescription)",
                english: "Could not delete the major category. \(error.localizedDescription)"
            )
        }
    }

    func performQuickAction(
        _ action: WidgetAction,
        planID: UUID,
        at date: Date = .now
    ) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        let plan = snapshot.plans[index]
        do {
            switch action {
            case .complete, .stopCurrentActivity:
                let result = QuickActionEngine.complete(
                    plan: plan,
                    actuals: snapshot.actuals,
                    at: date,
                    copyPlannedDurationWhenMissing: action == .complete
                )
                snapshot.plans[index] = result.plan
                snapshot.actuals = result.actuals
                let majorCategory = currentMajorCategory(for: result.plan)
                try? await liveActivityController.stop(
                    plan: result.plan,
                    catStyle: snapshot.settings.catStyle,
                    majorCategoryID: majorCategory.id,
                    majorCategoryTitle: majorCategory.title,
                    majorCategorySystemImage: majorCategory.systemImage
                )
            case .postponeThirtyMinutes:
                snapshot.plans[index] = try QuickActionEngine.postpone(plan: plan)
            case .moveToNextFreeTime:
                let occupied = snapshot.plans
                    .filter { $0.id != planID && $0.status != .skipped }
                    .map(\.span)
                    + snapshot.calendarEvents.map(\.span)
                snapshot.plans[index] = try QuickActionEngine.moveToNextFreeTime(
                    plan: plan,
                    occupied: occupied,
                    after: date
                )
            }
            await persist()
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 처리하지 못했습니다. \(error.localizedDescription)",
                english: "Could not process the plan. \(error.localizedDescription)"
            )
        }
    }

    func startPlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        let result = QuickActionEngine.start(
            plan: snapshot.plans[index],
            actuals: snapshot.actuals,
            at: date
        )
        snapshot.plans[index] = result.plan
        snapshot.actuals = result.actuals
        let majorCategory = currentMajorCategory(for: result.plan)
        let projection = currentLiveActivityProjection()
        do {
            _ = try await liveActivityController.start(
                plan: result.plan,
                catStyle: snapshot.settings.catStyle,
                majorCategoryID: majorCategory.id,
                majorCategoryTitle: majorCategory.title,
                majorCategorySystemImage: majorCategory.systemImage,
                compactActivityTitle: projection.title,
                compactActivityCategoryID: projection.categoryID
            )
        } catch LiveActivityError.unavailable {
            // The plan timer still works when Live Activities are disabled.
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "Live Activity를 시작하지 못했습니다. \(error.localizedDescription)",
                english: "Could not start the Live Activity. \(error.localizedDescription)"
            )
        }
        await persist()
    }

    func pausePlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        snapshot.plans[index].status = .planned
        snapshot.plans[index].updatedAt = date
        if let actualIndex = snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.endedAt == nil
        }) {
            snapshot.actuals[actualIndex].endedAt = max(
                snapshot.actuals[actualIndex].startedAt,
                date
            )
        }
        let majorCategory = currentMajorCategory(for: snapshot.plans[index])
        try? await liveActivityController.stop(
            plan: snapshot.plans[index],
            catStyle: snapshot.settings.catStyle,
            majorCategoryID: majorCategory.id,
            majorCategoryTitle: majorCategory.title,
            majorCategorySystemImage: majorCategory.systemImage
        )
        await persist()
    }

    func skipPlan(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        snapshot.plans[index] = QuickActionEngine.skip(plan: snapshot.plans[index])
        await persist()
    }

    private func applyWatchCommand(_ command: TaptionWatchCommand) async {
        // 애플워치 연동을 끄면 워치에서 온 명령을 받지 않는다.
        guard UserDefaults.standard.object(forKey: "appleWatchLinkEnabled") as? Bool ?? true else { return }
        guard !TaptionExternalPrivacyStore.isLocked,
              acceptsDataMutation(capturedAt: command.requestedAt) else {
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        switch command.kind {
        case .start:
            await startPlan(command.planID, at: command.requestedAt)
        case .complete:
            await performQuickAction(
                .complete,
                planID: command.planID,
                at: command.requestedAt
            )
        case .postponeThirtyMinutes:
            await performQuickAction(
                .postponeThirtyMinutes,
                planID: command.planID,
                at: command.requestedAt
            )
        case .skip:
            await skipPlan(command.planID)
        case .stopCurrentActivity:
            await performQuickAction(
                .stopCurrentActivity,
                planID: command.planID,
                at: command.requestedAt
            )
        }
    }

    private func noteAppleWatchDataReceived(
        _ kinds: Set<AppleWatchDataKind>,
        measuredAt: Date,
        receivedAt: Date = .now,
        requestID: String? = nil
    ) {
        guard !kinds.isEmpty else { return }
        let hadPendingRequest = appleWatchDataSyncRequestedAt != nil
        let receipt = appleWatchDataReceiptStore.record(
            kinds,
            measuredAt: measuredAt,
            receivedAt: receivedAt
        )
        let latestDataAt = receipt.latestDataAt
        if appleWatchLastDataReceivedAt != latestDataAt {
            appleWatchLastDataReceivedAt = latestDataAt
        }
        let clearedPendingRequest: Bool
        if let requestedAt = appleWatchDataSyncRequestedAt,
           AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
               requestedAt: requestedAt,
               expectedRequestID: appleWatchDataSyncRequestID,
               receivedRequestID: requestID,
               measuredAt: measuredAt,
               receivedAt: receivedAt
           ) {
            appleWatchDataSyncRequestedAt = nil
            appleWatchDataSyncRequestID = nil
            appleWatchDataSyncRequestStatus = nil
            clearedPendingRequest = true
        } else {
            clearedPendingRequest = false
        }
        let recentKinds = receipt.recentKinds(at: receivedAt)
        if appleWatchReceivedDataKinds != recentKinds {
            appleWatchReceivedDataKinds = recentKinds
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_receipt_recorded",
            fields: [
                "kinds": kinds.map(\.rawValue).sorted().joined(separator: ","),
                "measured_at": String(measuredAt.timeIntervalSince1970),
                "received_at": String(receivedAt.timeIntervalSince1970),
                "latest_received_at": receipt.latestDataAt.map {
                    String($0.timeIntervalSince1970)
                } ?? "none",
                "pending_before": String(hadPendingRequest),
                "pending_cleared": String(clearedPendingRequest),
                "request_id": requestID ?? "none",
                "pending_after": String(
                    appleWatchDataSyncRequestedAt != nil
                ),
                "recent_kinds": recentKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
            ]
        )
    }

    private func applyWatchAccelerationChunk(
        _ chunk: TaptionWatchAccelerationChunk,
        receivedAt: Date,
        requestID: String?
    ) async -> Bool {
        let deletionCutoff = TaptionDataDeletionFence.cutoff()
        guard let chunk = chunk.retainingData(
            after: deletionCutoff,
            receivedAt: receivedAt
        ) else {
            return deletionCutoff.map { cutoff in
                chunk.endedAt <= cutoff
                    || chunk.samples.allSatisfy { $0.capturedAt <= cutoff }
            } ?? false
        }
        guard acceptsDataMutation(capturedAt: chunk.endedAt) else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_acceleration_chunk_apply_started",
            fields: [
                "chunk": chunk.id.uuidString,
                "samples": String(chunk.samples.count),
                "start": String(chunk.startedAt.timeIntervalSince1970),
                "end": String(chunk.endedAt.timeIntervalSince1970),
                "received_at": String(receivedAt.timeIntervalSince1970),
                "request_id": requestID ?? "none",
            ]
        )
        var storedInDayDatabase = false
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchAccelerationChunk(chunk)
                storedInDayDatabase = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_day_database_recorded",
                    fields: ["chunk": chunk.id.uuidString]
                )
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_day_database_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "chunk": chunk.id.uuidString,
                    ]) { _, new in new }
                )
            }
        }
        guard storedInDayDatabase else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_acceleration_persistence_failed",
                level: .error,
                fields: ["chunk": chunk.id.uuidString]
            )
            return false
        }
        noteAppleWatchDataReceived(
            [.motion],
            measuredAt: chunk.endedAt,
            receivedAt: receivedAt,
            requestID: requestID
        )
        invalidateRawDays([chunk.startedAt, chunk.endedAt])
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_acceleration_chunk_applied",
            fields: [
                "chunk": chunk.id.uuidString,
                "samples": String(chunk.samples.count),
            ]
        )
        guard acceptsDataMutation(capturedAt: chunk.endedAt) else { return true }
        scheduleSensorAnalysis(
            containing: chunk.startedAt,
            immediately: chunk.isFinal
        )
        if !Calendar.autoupdatingCurrent.isDate(
            chunk.startedAt,
            inSameDayAs: chunk.endedAt
        ) {
            scheduleSensorAnalysis(
                containing: chunk.endedAt,
                immediately: chunk.isFinal
            )
        }
        return true
    }

    private func applyWatchSensorSummary(
        _ summary: TaptionWatchSensorSummary,
        receivedAt: Date,
        requestID: String?
    ) async -> Bool {
        let deletionCutoff = TaptionDataDeletionFence.cutoff()
        guard let summary = summary.retainingData(
            after: deletionCutoff,
            receivedAt: receivedAt
        ) else {
            return deletionCutoff.map {
                summary.startedAt <= $0 || summary.endedAt <= $0
            } ?? false
        }
        guard acceptsDataMutation(capturedAt: summary.endedAt) else {
            return false
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        do {
            try await restoreWatchSummaryHighWaterIfNeeded(for: summary)
        } catch {
            return false
        }
        let version = WatchSummaryVersion(
            sequence: summary.sequence,
            revision: summary.ambientRevision ?? 0
        )
        let previousVersion = latestWatchSummaryVersion[summary.sessionID]
        let appliedVersion = appliedWatchSummaryVersion[summary.sessionID]
        let isOlder = previousVersion.map { version < $0 } ?? false
        let isAlreadyApplied = appliedVersion.map { version <= $0 } ?? false
        if isOlder {
            guard await persistWatchSummaryForDelivery(summary) else {
                return false
            }
            guard await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt) else {
                return false
            }
            Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
            if let previousVersion,
               appliedVersion.map({ $0 < previousVersion }) ?? true {
                let latest: TaptionWatchSensorSummary?
                do {
                    latest = try await latestPersistedWatchSummary(
                        for: summary.sessionID
                    )
                } catch {
                    return false
                }
                guard let latest,
                      Self.watchSummaryVersion(latest) == previousVersion else {
                    return false
                }
                return await applyWatchSensorSummary(
                    latest,
                    receivedAt: receivedAt,
                    requestID: requestID
                )
            }
            return true
        }
        if isAlreadyApplied {
            guard await persistWatchSummaryForDelivery(summary),
                  await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt) else {
                return false
            }
            Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
            return true
        }
        latestWatchSummaryVersion[summary.sessionID] = version
        if summary.isFinal {
            finalizedWatchSummarySessionIDs.insert(summary.sessionID)
        }
        var dataKinds: Set<AppleWatchDataKind> = [.motion, .activity]
        if summary.latestHeartRate != nil
            || summary.averageHeartRate != nil
            || summary.maximumHeartRate != nil {
            dataKinds.insert(.heartRate)
        }
        if !(summary.routePoints ?? []).isEmpty {
            dataKinds.insert(.route)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_sensor_summary_apply_started",
            fields: [
                "sequence": String(summary.sequence),
                "samples": String(summary.accelerometerSampleCount),
                "final": String(summary.isFinal),
                "ambient": String(summary.isAmbient == true),
                "has_route": String(!(summary.routePoints ?? []).isEmpty),
                "data_kinds": dataKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
            ]
        )
        var storedInDayDatabase = false
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchSummary(summary)
                storedInDayDatabase = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_day_database_merge_succeeded",
                    fields: ["sequence": String(summary.sequence)]
                )
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_day_database_merge_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "sequence": String(summary.sequence),
                    ]) { _, new in new }
                )
            }
        }
        guard storedInDayDatabase else {
            if acceptsDataMutation(capturedAt: summary.endedAt) {
                userFacingError = AppLanguagePreference.text(
                    korean: "Apple Watch 센서 기록을 저장하지 못했습니다.",
                    english: "Could not save Apple Watch sensor records."
                )
            }
            if latestWatchSummaryVersion[summary.sessionID] == version {
                latestWatchSummaryVersion[summary.sessionID] = previousVersion
                if summary.isFinal {
                    finalizedWatchSummarySessionIDs.remove(summary.sessionID)
                }
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_sensor_summary_persistence_failed",
                level: .error,
                fields: [
                    "session": summary.sessionID.uuidString,
                    "sequence": String(summary.sequence),
                ]
            )
            return false
        }
        Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
        guard latestWatchSummaryVersion[summary.sessionID] == version else {
            return false
        }
        noteAppleWatchDataReceived(
            dataKinds,
            measuredAt: summary.endedAt,
            receivedAt: receivedAt,
            requestID: requestID
        )
        if let heartRate = summary.latestHeartRate,
           heartRate.isFinite, heartRate > 0 {
            latestHeartRate = heartRate
            latestHeartRateUpdatedAt = summary.endedAt
        }
        if summary.isFinal {
            if activeTrackingSession?.id == summary.sessionID {
                activeTrackingSession = nil
                trackingSessionWasRecovered = false
                liveRouteState.session = nil
                TrackingSessionRecoveryStore.clear()
                lastTrackingSessionRecoveryPersistAt = nil
            }
        } else if summary.isAmbient != true,
                  activeTrackingSession == nil {
            let kind: TrackingKind = summary.workoutKind == .running
                ? .running
                : .walking
            let session = TrackingSession(
                id: summary.sessionID,
                kind: kind,
                startedAt: summary.startedAt,
                linkedPlanID: summary.linkedPlanID,
                sourceDevice: .appleWatch,
                iPhoneActive: false,
                watchActive: true,
                wasAutomaticallyDetected: false
            )
            activeTrackingSession = session
            liveRouteState = LiveRouteState(
                session: session,
                readings: [],
                lastUpdatedAt: summary.endedAt
            )
            TrackingSessionRecoveryStore.save(session)
            lastTrackingSessionRecoveryPersistAt = summary.endedAt
        }
        await archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-sensor-summary",
            payload: summary,
            capturedAt: summary.endedAt
        )
        guard acceptsDataMutation(capturedAt: summary.endedAt),
              isCurrentWatchSummary(summary, version: version)
        else { return false }
        dayLoadCoordinator?.invalidate(day: summary.startedAt)
        if !Calendar.autoupdatingCurrent.isDate(
            summary.startedAt,
            inSameDayAs: summary.endedAt
        ) {
            dayLoadCoordinator?.invalidate(day: summary.endedAt)
        }
        let atHome = isWatchSummaryAtHome(summary)
        let resolution = WatchActivityPersonalizationEngine.resolve(
            summary,
            atHome: atHome,
            learnedSamples: WatchActivityLearningStore.read()
        )
        var interpretedSummary = summary
        if let learned = resolution.learnedBehavior {
            interpretedSummary.behavior = learned.kind
            interpretedSummary.behaviorConfidenceScore = learned.confidenceScore
            interpretedSummary.behaviorEvidence = Array(Set(
                (summary.behaviorEvidence ?? []) + learned.evidence
            )).sorted()
            interpretedSummary.behaviorModelVersion = learned.modelVersion
        }
        let previousSuggestion = pendingWatchActivitySuggestion
        if let suggestion = resolution.suggestion {
            pendingWatchActivitySuggestion = mergingWatchSuggestion(suggestion)
        } else if resolution.learnedBehavior != nil
                    || (pendingWatchActivitySuggestion?.sensorSessionID
                        == summary.sessionID && summary.isFinal) {
            pendingWatchActivitySuggestion = nil
        }
        if previousSuggestion != pendingWatchActivitySuggestion {
            publishWatchPayload()
        }
        if summary.isAmbient != true {
            guard await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt),
                  isCurrentWatchSummary(summary, version: version) else {
                return false
            }
        }
        let linkedPlan = summary.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        if resolution.suggestion == nil {
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                interpretedSummary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: atHome
            )
        } else {
            // 답변 전에는 후보를 최종 활동으로 보이지 않는다. 원시 센서와
            // 요약 아카이브는 위에서 이미 보존했다.
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == summary.sessionID
                        || $0.sensorChunkID == summary.sessionID)
            }
        }
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
        guard await persistDeviceLocalSnapshot() else { return false }
        guard acceptsDataMutation(capturedAt: summary.endedAt),
              isCurrentWatchSummary(summary, version: version) else {
            return false
        }
        markWatchSummaryApplied(version, for: summary.sessionID)
        scheduleSensorAnalysis(
            containing: summary.startedAt,
            immediately: summary.isFinal
        )
        if !Calendar.autoupdatingCurrent.isDate(
            summary.startedAt,
            inSameDayAs: summary.endedAt
        ) {
            scheduleSensorAnalysis(
                containing: summary.endedAt,
                immediately: summary.isFinal
            )
        }
        return true
    }

    private func persistWatchSummaryReadings(
        _ summary: TaptionWatchSensorSummary
    ) async -> Bool {
        guard summary.isAmbient != true, let sensorService else { return true }
        let routePoints = summary.routePoints ?? []
        let watchAccelerationAverageG = summary.accelerometerAverageG.map {
            SensorVector3(x: $0.x, y: $0.y, z: $0.z)
        }
        let routeSpeeds = routePoints.compactMap(\.speedMetersPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
        let routeAverageSpeed = routeSpeeds.isEmpty
            ? nil
            : routeSpeeds.reduce(0, +) / Double(routeSpeeds.count)
        let behavior = summary.behavior.map {
            WatchBehaviorInference(
                kind: $0,
                confidenceScore: summary.behaviorConfidenceScore ?? 0.5,
                evidence: summary.behaviorEvidence ?? [],
                modelVersion: summary.behaviorModelVersion
                    ?? WatchBehaviorClassifier.rulesVersion
            )
        } ?? WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                workoutKind: summary.workoutKind,
                duration: summary.endedAt.timeIntervalSince(
                    summary.startedAt
                ),
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
                gpsAverageSpeedMetersPerSecond: routeAverageSpeed,
                gpsAvailable: !routePoints.isEmpty,
                gpsLossRatio: routePoints.isEmpty ? 1 : 0
            )
        )
        let watchMotion: MotionKind = switch behavior.kind {
        case .running: .running
        case .walking, .stairsUp, .stairsDown: .walking
        case .cycling: .cycling
        case .automotive, .publicTransit, .subway: .automotive
        case .stationary, .standing, .sitting, .lying, .elevator,
             .exercise, .brushingTeeth, .eating, .typing, .housework,
             .showering,
             .sleep, .unknown:
            .stationary
        }
        let behaviorSegments = summary.behaviorSegments ?? []
        func behaviorAt(_ date: Date) -> WatchBehaviorInference {
            guard let segment = behaviorSegments.first(where: {
                $0.startedAt <= date && date < $0.endedAt
            }) else { return behavior }
            return WatchBehaviorInference(
                kind: segment.behavior,
                confidenceScore: segment.confidenceScore,
                evidence: segment.evidence,
                modelVersion: segment.modelVersion
            )
        }
        func motionKind(for inference: WatchBehaviorInference) -> MotionKind {
            switch inference.kind {
            case .running: .running
            case .walking, .stairsUp, .stairsDown: .walking
            case .cycling: .cycling
            case .automotive, .publicTransit, .subway: .automotive
            default: .stationary
            }
        }
        var readings = routePoints.enumerated().map { offset, point in
            let pointBehavior = behaviorAt(point.capturedAt)
            return SensorReading(
                id: point.id,
                timestamp: point.capturedAt,
                point: GeoPoint(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy
                ),
                speedMetersPerSecond: point.speedMetersPerSecond,
                courseDegrees: point.courseDegrees,
                motion: motionKind(for: pointBehavior),
                motionConfidence: ConfidenceLevel(
                    score: pointBehavior.confidenceScore
                ),
                relativeAltitudeMeters: summary.relativeAltitudeMeters,
                pressureKilopascals: summary.pressureKilopascals,
                altimeterSessionID: summary.sessionID,
                floorsAscended: summary.floorsAscended,
                floorsDescended: summary.floorsDescended,
                stepCount: summary.stepCount,
                walkingRunningDistanceMeters: summary.distanceMeters,
                watchAccelerationAverageG: watchAccelerationAverageG,
                watchAccelerationStandardDeviationG:
                    summary.accelerometerStandardDeviationG,
                watchAccelerationMeanJerkGPerSecond:
                    summary.accelerometerMeanJerkGPerSecond,
                gpsAvailable: true,
                watchWorkoutKind: summary.workoutKind.rawValue,
                behavior: pointBehavior.kind.rawValue,
                behaviorConfidenceScore: pointBehavior.confidenceScore,
                behaviorEvidence: pointBehavior.evidence,
                behaviorModelVersion: pointBehavior.modelVersion,
                trackingSessionID: summary.sessionID,
                trackingKind: summary.workoutKind == .running
                    ? .running
                    : .walking,
                sourceDevice: .appleWatch,
                sequence: summary.sequence * 10_000 + offset,
                trackingSessionEnded: false
            )
        }
        if readings.isEmpty,
           summary.accelerometerSampleCount > 0,
           !summary.isFinal {
            readings.append(
                SensorReading(
                    id: summary.fallbackReadingID,
                    timestamp: summary.endedAt,
                    motion: watchMotion,
                    motionConfidence: .medium,
                    relativeAltitudeMeters: summary.relativeAltitudeMeters,
                    pressureKilopascals: summary.pressureKilopascals,
                    altimeterSessionID: summary.sessionID,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    stepCount: summary.stepCount,
                    walkingRunningDistanceMeters: summary.distanceMeters,
                    watchAccelerationAverageG: watchAccelerationAverageG,
                    watchAccelerationStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    watchAccelerationMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    gpsAvailable: false,
                    watchWorkoutKind: summary.workoutKind.rawValue,
                    behavior: behavior.kind.rawValue,
                    behaviorConfidenceScore: behavior.confidenceScore,
                    behaviorEvidence: behavior.evidence,
                    behaviorModelVersion: behavior.modelVersion,
                    trackingSessionID: summary.sessionID,
                    trackingKind: summary.workoutKind == .running
                        ? .running
                        : .walking,
                    sourceDevice: .appleWatch,
                    sequence: summary.sequence * 10_000,
                    trackingSessionEnded: summary.isFinal
                )
            )
        }
        if summary.isFinal {
            readings.append(
                SensorReading(
                    id: summary.sessionID,
                    timestamp: summary.endedAt,
                    motion: watchMotion,
                    motionConfidence: ConfidenceLevel(
                        score: behavior.confidenceScore
                    ),
                    relativeAltitudeMeters: summary.relativeAltitudeMeters,
                    pressureKilopascals: summary.pressureKilopascals,
                    altimeterSessionID: summary.sessionID,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    stepCount: summary.stepCount,
                    walkingRunningDistanceMeters: summary.distanceMeters,
                    watchAccelerationAverageG: watchAccelerationAverageG,
                    watchAccelerationStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    watchAccelerationMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    gpsAvailable: false,
                    watchWorkoutKind: summary.workoutKind.rawValue,
                    behavior: behavior.kind.rawValue,
                    behaviorConfidenceScore: behavior.confidenceScore,
                    behaviorEvidence: behavior.evidence,
                    behaviorModelVersion: behavior.modelVersion,
                    trackingSessionID: summary.sessionID,
                    trackingKind: summary.workoutKind == .running
                        ? .running
                        : .walking,
                    sourceDevice: .appleWatch,
                    sequence: summary.sequence * 10_000 + routePoints.count,
                    trackingSessionEnded: true
                )
            )
        }
        do {
            try await sensorService.recordExternalReadings(readings)
        } catch {
            Self.integrationLogger.error(
                "Watch route archive failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func persistWatchSummaryForDelivery(
        _ summary: TaptionWatchSensorSummary
    ) async -> Bool {
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchSummary(summary)
                return true
            } catch { }
        }
        return false
    }

    private func latestPersistedWatchSummary(
        for sessionID: UUID
    ) async throws -> TaptionWatchSensorSummary? {
        try await dayDatabase?.latestWatchSummary(for: sessionID)
    }

    private func restoreWatchSummaryHighWaterIfNeeded(
        for summary: TaptionWatchSensorSummary
    ) async throws {
        let sessionID = summary.sessionID
        guard !restoredWatchSummarySessions.contains(sessionID) else { return }

        var restored = latestWatchSummaryVersion[sessionID]
        let cached = Self.persistedWatchSummaryHighWater(for: sessionID)
        if let saved = cached {
            restored = max(restored ?? saved, saved)
        }
        let applied = Self.persistedAppliedWatchSummaryHighWater(
            for: sessionID
        )
        if let applied {
            appliedWatchSummaryVersion[sessionID] = applied
            restored = max(restored ?? applied, applied)
        }

        var persisted: WatchSummaryVersion?
        if let dayDatabase,
           let latest = try await dayDatabase.latestWatchSummary(for: sessionID) {
            persisted = WatchSummaryVersion(
                sequence: latest.sequence,
                revision: latest.ambientRevision ?? 0
            )
        }
        if let persisted {
            restored = max(restored ?? persisted, persisted)
            Self.persistWatchSummaryHighWater(persisted, for: sessionID)
        }

        if let latest = latestWatchSummaryVersion[sessionID] {
            latestWatchSummaryVersion[sessionID] = max(restored ?? latest, latest)
        } else {
            latestWatchSummaryVersion[sessionID] = restored
        }
        restoredWatchSummarySessions.insert(sessionID)
    }

    private func isCurrentWatchSummary(
        _ summary: TaptionWatchSensorSummary,
        version: WatchSummaryVersion
    ) -> Bool {
        latestWatchSummaryVersion[summary.sessionID] == version
            && (summary.isFinal
                || !finalizedWatchSummarySessionIDs.contains(summary.sessionID))
    }

    private static func persistedWatchSummaryHighWater(
        for sessionID: UUID
    ) -> WatchSummaryVersion? {
        let key = watchSummaryHighWaterKeyPrefix + sessionID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(
            WatchSummaryVersion.self,
            from: data
        )
    }

    private static func persistedAppliedWatchSummaryHighWater(
        for sessionID: UUID
    ) -> WatchSummaryVersion? {
        let key = watchSummaryAppliedHighWaterKeyPrefix + sessionID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(
            WatchSummaryVersion.self,
            from: data
        )
    }

    private func markWatchSummaryApplied(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let applied = max(
            appliedWatchSummaryVersion[sessionID] ?? version,
            version
        )
        appliedWatchSummaryVersion[sessionID] = applied
        Self.persistAppliedWatchSummaryHighWater(applied, for: sessionID)
    }

    private static func persistWatchSummaryHighWater(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let defaults = UserDefaults.standard
        let key = watchSummaryHighWaterKeyPrefix + sessionID.uuidString
        if let current = persistedWatchSummaryHighWater(for: sessionID),
           current >= version {
            return
        }
        guard let data = try? PropertyListEncoder().encode(version) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func persistAppliedWatchSummaryHighWater(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let defaults = UserDefaults.standard
        let key = watchSummaryAppliedHighWaterKeyPrefix + sessionID.uuidString
        if let current = persistedAppliedWatchSummaryHighWater(for: sessionID),
           current >= version {
            return
        }
        guard let data = try? PropertyListEncoder().encode(version) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func watchSummaryVersion(
        _ summary: TaptionWatchSensorSummary
    ) -> WatchSummaryVersion {
        WatchSummaryVersion(
            sequence: summary.sequence,
            revision: summary.ambientRevision ?? 0
        )
    }

    private static func clearPersistedWatchSummaryHighWater() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(watchSummaryHighWaterKeyPrefix)
                || key.hasPrefix(watchSummaryAppliedHighWaterKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Watch의 답을 파생 기록과 개인화 표본에 반영한다. 원시 센서 아카이브는
    /// 수정하지 않으며 같은 패턴이 충분히 쌓이기 전까지 자동 확정하지 않는다.
    private func applyWatchActivityConfirmation(
        _ confirmation: TaptionWatchActivityConfirmation,
        receivedAt: Date
    ) async {
        guard let confirmation = confirmation.retainingData(
            after: TaptionDataDeletionFence.cutoff(),
            receivedAt: receivedAt
        ) else { return }
        guard acceptsDataMutation(capturedAt: confirmation.respondedAt) else {
            return
        }
        guard let suggestion = pendingWatchActivitySuggestion,
              let confirmationToken = suggestion.confirmationToken,
              confirmation.suggestionID == suggestion.id,
              confirmation.sensorSessionID == suggestion.sensorSessionID,
              confirmation.confirmationToken == confirmationToken,
              confirmation.observedStartedAt == suggestion.startedAt,
              confirmation.observedEndedAt == suggestion.endedAt,
              confirmation.observedBehavior == suggestion.proposedBehavior
        else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_activity_confirmation_rejected",
                level: .notice,
                fields: ["reason": "missing_or_invalid_capability"]
            )
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !WatchActivityConfirmationStore.read().contains(where: {
            $0.id == confirmation.id
        }) else { return }
        WatchActivityConfirmationStore.append(confirmation)
        let label = confirmation.isCorrect
            ? confirmation.observedBehavior
            : confirmation.correctedBehavior
        if let label {
            let pattern = suggestion.pattern
            WatchActivityLearningStore.append(
                WatchActivityPatternSample(
                    id: confirmation.id,
                    capturedAt: confirmation.respondedAt,
                    pattern: pattern,
                    label: label
                )
            )
        }
        if let label {
            let sessionID = confirmation.sensorSessionID
                ?? suggestion.sensorSessionID
            let previous = snapshot.actuals.first {
                $0.id == sessionID && $0.source == .appleWatch
            }
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == sessionID || $0.sensorChunkID == sessionID)
            }
            snapshot.actuals.append(
                ActualRecord(
                    id: sessionID,
                    planID: nil,
                    title: label.title,
                    categoryID: watchCategoryID(for: label),
                    startedAt: confirmation.observedStartedAt,
                    endedAt: confirmation.observedEndedAt,
                    source: .appleWatch,
                    confidence: .high,
                    createdAt: previous?.createdAt
                        ?? confirmation.observedStartedAt,
                    behavior: label.rawValue,
                    evidence: Array(Set(
                        suggestion.evidence + ["사용자 확인"]
                    )).sorted(),
                    sensorChunkID: sessionID,
                    modelVersion:
                        WatchActivityPersonalizationEngine.modelVersion,
                    manuallyCorrected: true
                )
            )
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
            dayLoadCoordinator?.invalidate(day: confirmation.observedStartedAt)
            if !Calendar.autoupdatingCurrent.isDate(
                confirmation.observedStartedAt,
                inSameDayAs: confirmation.observedEndedAt
            ) {
                dayLoadCoordinator?.invalidate(day: confirmation.observedEndedAt)
            }
        }
        if pendingWatchActivitySuggestion?.id == confirmation.suggestionID {
            pendingWatchActivitySuggestion = nil
        }
        Self.integrationLogger.notice(
            "Watch activity confirmation received: correct=\(confirmation.isCorrect, privacy: .public)"
        )
        await persistDeviceLocalSnapshot()
    }

    private func mergingWatchSuggestion(
        _ candidate: TaptionWatchActivitySuggestion
    ) -> TaptionWatchActivitySuggestion {
        guard let current = pendingWatchActivitySuggestion,
              current.sensorSessionID == candidate.sensorSessionID,
              current.proposedBehavior == candidate.proposedBehavior,
              candidate.startedAt <= current.endedAt.addingTimeInterval(10 * 60)
        else { return candidate }
        var merged = candidate
        merged.id = current.id
        merged.startedAt = min(current.startedAt, candidate.startedAt)
        merged.evidence = Array(Set(current.evidence + candidate.evidence))
            .sorted()
        return merged
    }

    private func watchCategoryID(for behavior: WatchBehaviorKind) -> String {
        if behavior.isMovement { return "movement" }
        if behavior == .sleep { return "sleep" }
        return "activity"
    }

    private func applyWatchHealthSnapshot(
        _ snapshot: TaptionWatchHealthSnapshot,
        receivedAt: Date,
        requestID: String?
    ) async {
        guard let snapshot = snapshot.retainingData(
            after: TaptionDataDeletionFence.cutoff(),
            receivedAt: receivedAt
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_ignored",
                level: .notice,
                fields: ["reason": "deletion_or_invalid_timestamp"]
            )
            return
        }
        guard acceptsDataMutation(capturedAt: snapshot.capturedAt) else {
            return
        }
        let rawPayloadFingerprint = (
            try? RawDeviceDataEnvelope.payloadEncoder().encode(snapshot)
        ).map(TaptionPlanCanonicalStorage.checksum)
        guard WatchHealthSnapshotRetryPolicy.accepts(
            capturedAt: snapshot.capturedAt,
            fingerprint: rawPayloadFingerprint,
            receivedAt: receivedAt,
            lastAppliedAt: lastWatchHealthSnapshotCapturedAt,
            rawRetryAt: lastWatchHealthSnapshotRawRetryAt,
            rawRetryFingerprint:
                lastWatchHealthSnapshotRawRetryFingerprint,
            lastRawRetryAttemptAt:
                lastWatchHealthSnapshotRawRetryAttemptAt
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_ignored",
                fields: ["reason": "stale_or_duplicate"]
            )
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        var dataKinds: Set<AppleWatchDataKind> = [.health]
        if snapshot.workoutCount > 0 {
            dataKinds.insert(.activity)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_health_snapshot_apply_started",
            fields: [
                "workout_count": String(snapshot.workoutCount),
                "sleep_minutes": String(snapshot.sleepMinutes ?? 0),
                "sleep_payload_present": String(
                    !(snapshot.sleepSegments?.isEmpty ?? true)
                ),
                "sleep_segment_count": String(
                    snapshot.sleepSegments?.count ?? 0
                ),
                "data_kinds": dataKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
                "health_enabled": String(settings.healthEnabled),
            ]
        )
        let isRawRetry = snapshot.capturedAt
            == lastWatchHealthSnapshotCapturedAt
        if isRawRetry {
            lastWatchHealthSnapshotRawRetryAttemptAt = receivedAt
            let rawArchived = await archiveRawDeviceData(
                source: .appleWatch,
                kind: "watch-health-snapshot",
                payload: snapshot,
                capturedAt: snapshot.capturedAt
            )
            guard rawArchived else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_health_snapshot_raw_retry_failed",
                    level: .error,
                    fields: [
                        "captured_at": String(
                            snapshot.capturedAt.timeIntervalSince1970
                        ),
                    ]
                )
                return
            }
            lastWatchHealthSnapshotRawRetryAt = nil
            lastWatchHealthSnapshotRawRetryFingerprint = nil
            lastWatchHealthSnapshotRawRetryAttemptAt = nil
            noteAppleWatchDataReceived(
                dataKinds,
                measuredAt: snapshot.capturedAt,
                receivedAt: receivedAt,
                requestID: requestID
            )
            return
        }
        let rawArchived = await archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-health-snapshot",
            payload: snapshot,
            capturedAt: snapshot.capturedAt
        )
        if !rawArchived {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_raw_persistence_failed",
                level: .error,
                fields: [
                    "captured_at": String(
                        snapshot.capturedAt.timeIntervalSince1970
                    ),
                    "derived_fallback": "true",
                ]
            )
        }
        guard acceptsDataMutation(capturedAt: snapshot.capturedAt) else {
            return
        }
        guard WatchHealthSnapshotRetryPolicy.accepts(
            capturedAt: snapshot.capturedAt,
            fingerprint: rawPayloadFingerprint,
            receivedAt: receivedAt,
            lastAppliedAt: lastWatchHealthSnapshotCapturedAt,
            rawRetryAt: lastWatchHealthSnapshotRawRetryAt,
            rawRetryFingerprint:
                lastWatchHealthSnapshotRawRetryFingerprint,
            lastRawRetryAttemptAt:
                lastWatchHealthSnapshotRawRetryAttemptAt
        ) else {
            return
        }
        lastWatchHealthSnapshotCapturedAt = snapshot.capturedAt
        lastWatchHealthSnapshotRawRetryAt = rawArchived ? nil : snapshot.capturedAt
        lastWatchHealthSnapshotRawRetryFingerprint = rawArchived
            ? nil
            : rawPayloadFingerprint
        lastWatchHealthSnapshotRawRetryAttemptAt = rawArchived
            ? nil
            : receivedAt
        if rawArchived {
            noteAppleWatchDataReceived(
                dataKinds,
                measuredAt: snapshot.capturedAt,
                receivedAt: receivedAt,
                requestID: requestID
            )
        }
        var watchSleepSessionCount = 0
        if let segments = snapshot.sleepSegments, !segments.isEmpty {
            let sleepSegments = segments.compactMap { segment -> SleepSegment? in
                guard let stage = SleepStage(rawValue: segment.stage),
                      segment.endDate > segment.startDate else {
                    return nil
                }
                return SleepSegment(
                    id: segment.id,
                    stage: stage,
                    span: TimeSpan(
                        start: segment.startDate,
                        end: segment.endDate
                    ),
                    sourceName: segment.sourceName,
                    sourceBundleIdentifier: segment.sourceBundleIdentifier,
                    deviceName: segment.deviceName,
                    timeZoneIdentifier: segment.timeZoneIdentifier,
                    isUserEntered: segment.isUserEntered
                )
            }
            let sessions = SleepAnalysisEngine().sessions(from: sleepSegments)
            watchSleepSessionCount = sessions.count
            if !sessions.isEmpty {
                let overnightSpan = SleepAnalysisEngine.overnightSpan(
                    containing: snapshot.capturedAt
                )
                sleepSessions.removeAll {
                    $0.isAppleWatchConfirmed
                        && $0.span.intersection(with: overnightSpan) != nil
                }
                sleepSessions.append(contentsOf: sessions)
                sleepSessions.sort { $0.span.start < $1.span.start }
                self.snapshot.actuals.removeAll {
                    $0.source == .appleWatch
                        && AutomaticRecordTimelineEngine.isSleep($0)
                        && $0.span(asOf: snapshot.capturedAt).intersection(
                            with: overnightSpan
                        ) != nil
                }
                self.snapshot.actuals = SleepActualReconciliationEngine.applying(
                    self.snapshot.actuals,
                    sessions: sessions,
                    inside: overnightSpan,
                    asOf: snapshot.capturedAt
                )
            }
        }
        let shouldRefreshHealth = settings.healthEnabled
            && (lastHealthRefreshAt.map {
                Date.now.timeIntervalSince($0)
                    >= HealthRefreshPolicy.foregroundInterval
            } ?? true)
        if shouldRefreshHealth {
            await refreshHealthData(showErrors: false)
        }
        await persistDeviceLocalSnapshot()
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_health_snapshot_applied",
            fields: [
                "workout_count": String(snapshot.workoutCount),
                "sleep_minutes": String(snapshot.sleepMinutes ?? 0),
                "sleep_segment_count": String(
                    snapshot.sleepSegments?.count ?? 0
                ),
                "sleep_sessions_created": String(watchSleepSessionCount),
                "health_refresh_requested": String(shouldRefreshHealth),
            ]
        )
    }

    private func isWatchSummaryAtHome(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        let homes = snapshot.settings.frequentPlaces.filter {
            $0.kind == .home && $0.point != nil
                && $0.isAutomaticRecordingEnabled
        }
        guard !homes.isEmpty else { return false }
        let span = TimeSpan(start: summary.startedAt, end: summary.endedAt)
        if snapshot.places.contains(where: { place in
            guard place.span.intersection(with: span) != nil else { return false }
            return homes.contains { home in
                place.displayName == home.name
                    || place.placeKey == home.stablePlaceKey
            }
        }) {
            return true
        }
        if summary.routePoints?.contains(where: { point in
            let coordinate = GeoPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.altitude,
                horizontalAccuracy: point.horizontalAccuracy,
                verticalAccuracy: point.verticalAccuracy
            )
            return homes.contains {
                guard let homePoint = $0.point else { return false }
                return distanceMeters(coordinate, homePoint) <= $0.radiusMeters
            }
        }) == true {
            return true
        }
        guard let latestSensorReading,
              let point = latestSensorReading.point,
              abs(latestSensorReading.timestamp.timeIntervalSince(summary.endedAt)) <= 10 * 60 else {
            return false
        }
        return homes.contains {
            guard let homePoint = $0.point else { return false }
            return distanceMeters(point, homePoint) <= $0.radiusMeters
        }
    }

    @discardableResult
    private func archiveRawDeviceData<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) async -> Bool {
        guard let rawDeviceDataArchive else { return false }
        do {
            let envelope = try RawDeviceDataEnvelope(
                capturedAt: capturedAt,
                source: source,
                kind: kind,
                payload: payload
            )
            try await rawDeviceDataArchive.append(envelope)
            return true
        } catch {
            Self.integrationLogger.error(
                "Raw device data archive failed: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func archiveWeatherRawContexts(
        _ contexts: [WeatherContext],
        kind: String
    ) async {
        guard let rawDeviceDataArchive else { return }
        let changes = WeatherTimelineEngine.changedRawContexts(
            contexts,
            relativeTo: snapshot.weather
        )
        guard !changes.isEmpty else { return }
        do {
            let envelopes = try changes.map { context in
                try RawDeviceDataEnvelope(
                    capturedAt: context.observedAt,
                    source: .gps,
                    kind: kind,
                    payload: context
                )
            }
            try await rawDeviceDataArchive.append(envelopes)
        } catch {
            Self.integrationLogger.error(
                "Weather raw archive failed: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func restoreRawWeather(in span: TimeSpan) async {
        guard let rawDeviceDataArchive,
              let envelopes = try? await rawDeviceDataArchive.envelopes(
                  in: span
              ) else {
            return
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let contexts = envelopes
            .filter {
                $0.source == .gps
                    && ($0.kind == "weather-context"
                        || $0.kind == "weather-forecast-hourly")
            }
            .compactMap { envelope -> WeatherContext? in
                guard let data = envelope.payloadJSON.data(using: .utf8) else {
                    return nil
                }
                if let byteCount = envelope.payloadByteCount,
                   byteCount != data.count {
                    return nil
                }
                if let checksum = envelope.payloadChecksum,
                   checksum != TaptionPlanCanonicalStorage.checksum(data) {
                    return nil
                }
                return try? decoder.decode(WeatherContext.self, from: data)
            }
        guard !contexts.isEmpty else { return }
        snapshot.weather = WeatherTimelineEngine.coalesced(
            snapshot.weather + contexts
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "weather_raw_restored",
            fields: [
                "envelopes": String(envelopes.count),
                "contexts": String(contexts.count),
                "from": String(span.start.timeIntervalSince1970),
                "through": String(span.end.timeIntervalSince1970),
            ]
        )
    }

    /// 이번 갱신이 실제로 신호를 들여다본 구간. 사진·건강 앱에서 메운 점은
    /// 연속 수집이 아니라 드문드문한 복원이므로 근거로 세지 않는다.
    private static func sensorEvidenceSpan(
        readings: [SensorReading],
        activities: [MotionActivityRecord],
        inside span: TimeSpan
    ) -> TimeSpan? {
        let moments = readings.map(\.timestamp)
            + activities.flatMap { [$0.span.start, $0.span.end] }
        guard let start = moments.min(), let end = moments.max() else {
            return nil
        }
        return TimeSpan(start: start, end: end).intersection(with: span)
    }

    /// 정지 구간을 "정지·휴식" 한 덩어리로 남기지 않고 장소·캘린더·시간
    /// 문맥으로 바꾼다. 새 권한이나 새 수집 없이 이미 모은 신호만 쓴다.
    private func applyStationaryContextRecords(
        stays: [PlaceStay],
        stationarySpans: [TimeSpan],
        travel: [TravelSegment],
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationSamples: [TaptionWatchAccelerationSample],
        evidence: TimeSpan?,
        inside span: TimeSpan
    ) async {
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let placeKinds = FrequentPlaceResolutionEngine()
            .kindsByPlaceKey(settings.frequentPlaces)
        let restaurantMealSpans = snapshot.actuals.compactMap { actual -> TimeSpan? in
            guard isAutomaticRestaurantMeal(actual) else { return nil }
            return actual.span(asOf: span.end).intersection(with: span)
        }
        let contextStays = stays.filter { stay in
            guard placeKinds[stay.placeKey] == .restaurant else { return true }
            return !restaurantMealSpans.contains {
                $0.intersection(with: stay.span) != nil
            }
        }
        let contextRecords = StationaryContextActualEngine.records(
            stays: contextStays,
            placeKinds: placeKinds,
            placeAnchors: FrequentPlaceResolutionEngine()
                .anchorsByPlaceKey(settings.frequentPlaces),
            stationarySpans: stationarySpans,
            readings: readings,
            calendarEvents: snapshot.calendarEvents,
            actuals: snapshot.actuals,
            travel: travel.filter {
                $0.span.intersection(with: span) != nil
            },
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let stableContextRecords = ActivityClassificationLockEngine
            .mergingLockedClassifications(
                existing: snapshot.actuals.filter {
                    $0.source == .location
                        && !isAutomaticRestaurantMeal($0)
                },
                fresh: contextRecords,
                inside: span
            )
        // 판독은 7일만 남는다. 그보다 오래된 날을 열면 문맥을 다시 만들 근거가
        // 없는데, 그때 저장된 기록까지 지우면 되살릴 길이 없다. 이번 갱신이
        // 실제로 들여다본 구간과 새로 만든 기록의 구간만 갈아끼운다.
        let refreshed = stableContextRecords.map { $0.span(asOf: span.end) }
            + [evidence].compactMap { $0?.intersection(with: span) }
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  (actual.modelVersion == StationaryContextClassifier.modelVersion
                    || actual.modelVersion == "stationary-context-v1"),
                  !isAutomaticRestaurantMeal(actual) else {
                return false
            }
            let stored = actual.span(asOf: span.end)
            return refreshed.contains {
                $0.intersection(with: stored) != nil
            }
        }
        guard !stableContextRecords.isEmpty else { return }
        snapshot.actuals = StationaryContextActualEngine
            .suppressingStationaryMotion(
                snapshot.actuals,
                coveredBy: stableContextRecords,
                asOf: span.end
            ) + stableContextRecords
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    private func applyPlaceActivityRecords(
        stays: [PlaceStay],
        inside span: TimeSpan
    ) {
        let kinds = FrequentPlaceResolutionEngine()
            .kindsByPlaceKey(settings.frequentPlaces)
        let candidates = stays.compactMap { stay in
            TaptionActivityEngineAdapter.placeActivityActual(
                for: stay, registeredKind: kinds[stay.placeKey], inside: span)
        }
        snapshot.actuals = PlaceActivityRefreshEngine.merge(
            existing: snapshot.actuals, candidates: candidates, inside: span,
            suppressedIDs: snapshot.settings.suppressedActualIDs)
        snapshot.actuals.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func isAutomaticRestaurantMeal(_ actual: ActualRecord) -> Bool {
        guard actual.source == .location else { return false }
        if actual.modelVersion == RestaurantMealActualEngine.modelVersion {
            return true
        }
        return (actual.modelVersion == StationaryContextClassifier.modelVersion
            || actual.modelVersion == "stationary-context-v1")
            && actual.behavior == StationaryContextKind.mealPlace.rawValue
            && actual.evidence.contains { $0.contains("자주가는 곳: 식당") }
    }

    private func applyRestaurantMealRecords(
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationSamples: [TaptionWatchAccelerationSample],
        inside span: TimeSpan
    ) {
        guard !readings.isEmpty else { return }
        let fresh = RestaurantMealActualEngine.records(
            restaurants: settings.frequentPlaces,
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        )
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  actual.span(asOf: span.end).intersection(with: span) != nil
            else { return false }
            return isAutomaticRestaurantMeal(actual)
        }
        guard !fresh.isEmpty else { return }
        snapshot.actuals.append(contentsOf: fresh)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    @discardableResult
    func refreshSensorTimeline(containing date: Date? = nil) async -> Bool {
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date ?? selectedDate)
        let key = "\(day.timeIntervalSince1970):\(rawDataRevision(for: day)):\(settings.hashValue)"
        if sensorTimelineRequestKey == key, let sensorTimelineTask {
            return await sensorTimelineTask.value
        }
        let previous = sensorTimelineTask
        previous?.cancel()
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return false }
            return await self.performSensorTimelineRefresh(containing: day)
        }
        sensorTimelineTask = task
        sensorTimelineRequestID = requestID
        sensorTimelineRequestKey = key
        defer {
            if sensorTimelineRequestID == requestID {
                sensorTimelineTask = nil
                sensorTimelineRequestID = nil
                sensorTimelineRequestKey = nil
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSensorTimelineRefresh(containing date: Date) async -> Bool {
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let snapshotBeforeRefresh = snapshot
        let latestSensorReadingBeforeRefresh = latestSensorReading
        let snapshotRevisionBeforeRefresh = snapshotRevision
        let dayProjectionRevisionBeforeRefresh = dayProjectionRevision
        let timelineRevisionBeforeRefresh = timelineRevision
        let needsLocalRecordNormalizationBeforeRefresh =
            needsLocalRecordNormalization
        let refreshFingerprintBeforeRefresh = sensorRefreshFingerprints[
            Calendar.autoupdatingCurrent.startOfDay(for: date)
        ]
        var committed = false
        isSensorTimelineRefreshing = true
        userEditedDuringSensorRefresh = false
        activeDataMutationCount += 1
        defer {
            if !committed, userEditedDuringSensorRefresh {
                // Keep the edit and the revisions that already guard its save.
                // Derived records are recomputed because the fingerprint is cleared.
                sensorRefreshFingerprints.removeValue(
                    forKey: Calendar.autoupdatingCurrent.startOfDay(for: date)
                )
                needsLocalRecordNormalization = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_refresh_rollback_skipped_for_user_edit"
                )
            } else if !committed {
                snapshot = snapshotBeforeRefresh
                latestSensorReading = latestSensorReadingBeforeRefresh
                let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
                if let refreshFingerprintBeforeRefresh {
                    sensorRefreshFingerprints[day] = refreshFingerprintBeforeRefresh
                } else {
                    sensorRefreshFingerprints.removeValue(forKey: day)
                }
                snapshotRevision = snapshotRevisionBeforeRefresh
                dayProjectionRevision = dayProjectionRevisionBeforeRefresh
                timelineRevision = timelineRevisionBeforeRefresh
                needsLocalRecordNormalization =
                    needsLocalRecordNormalizationBeforeRefresh
                activityClassificationRevisionFence.advance(
                    to: snapshotRevisionBeforeRefresh
                )
            }
            activeDataMutationCount -= 1
            isSensorTimelineRefreshing = false
            userEditedDuringSensorRefresh = false
        }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: date
        )
        let archivedReadings: [SensorReading]
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_refresh_started",
            fields: [
                "span_start": String(span.start.timeIntervalSinceReferenceDate),
                "span_end": String(span.end.timeIntervalSinceReferenceDate),
            ]
        )
        await restoreRawWeather(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        guard let sensorService else {
            committed = true
            return true
        }
        let watchData = await watchSensorTimelineData(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let watchSummaries = watchData.summaries
        let watchAccelerationSamples = watchData.accelerationSamples
        applyReplayedWatchSummaries(watchSummaries)
        do {
            archivedReadings = try await sensorService.archivedReadings(
                in: span
            )
        } catch is CancellationError {
            return false
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_read_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            userFacingError = AppModelMessage
                .locationReadFailed(error.localizedDescription).text()
            return false
        }
        // Raw readings stay in the archive. Every downstream algorithm uses
        // a copy whose scalar and route outliers are excluded with provenance.
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let qualityTask = Task.detached(priority: .utility) {
            try TaptionActivityEngineAdapter.qualityProjection(
                from: archivedReadings,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        let sensorQuality: TaptionSensorQualityProjection
        do {
            sensorQuality = try await withTaskCancellationHandler {
                try await qualityTask.value
            } onCancel: {
                qualityTask.cancel()
            }
        } catch is CancellationError {
            return false
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_quality_projection_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return false
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let filteredArchivedReadings = sensorQuality.routeReadings
        let sleepSpan = SleepAnalysisEngine.overnightSpan(
            containing: span.start
        )
        // The overnight session may begin before midnight. Read that raw
        // window separately so today's sensor-based result is not clipped to
        // 00:00, while route/place inference remains day-scoped.
        let sleepReadings = (try? await sensorService.archivedReadings(
            in: sleepSpan
        )) ?? []
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        if Calendar.autoupdatingCurrent.isDate(span.start, inSameDayAs: .now),
           let latest = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: filteredArchivedReadings
           ) {
            // Seed the live map anchor when the app is reopened before the
            // next Core Location callback arrives. Historical-day refreshes
            // must never replace the current-location anchor.
            latestSensorReading = latest
        }
        let motionActivities =
            (try? await sensorService.motionActivities(in: span)) ?? []
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_evidence_loaded",
            fields: [
                "gps": String(archivedReadings.count),
                "gps_filtered": String(filteredArchivedReadings.count),
                "motion": String(motionActivities.count),
                "quality_rejections": String(
                    sensorQuality.rejectionCounts.values.reduce(0, +)
                ),
                "impossible_location_count": String(sensorQuality.impossibleLocationCount),
                "innovation_outlier_count": String(sensorQuality.innovationOutlierCount),
            ]
        )
        let pedometer =
            try? await sensorService.pedometerSummary(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let healthKitMovementEvidence: [AppleMovementEvidence]
        if settings.healthEnabled {
            healthKitMovementEvidence =
                (try? await healthService.movementEvidence(in: span)) ?? []
        } else {
            healthKitMovementEvidence = []
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let refreshFingerprint = SensorRefreshFingerprint(
            readingCount: archivedReadings.count,
            latestReadingID: archivedReadings.last?.id,
            latestMotionEnd: motionActivities.map(\.span.end).max(),
            motionHash: motionActivities.hashValue,
            pedometerEnd: pedometer?.span.end,
            pedometerHash: pedometer?.hashValue,
            latestHealthEvidenceEnd: healthKitMovementEvidence
                .map(\.span.end)
                .max(),
            healthEvidenceHash: healthKitMovementEvidence.hashValue,
            watchSummaryCount: watchSummaries.count,
            latestWatchSummaryEnd: watchSummaries.map(\.endedAt).max(),
            watchAccelerationSampleCount: watchAccelerationSamples.count,
            latestWatchAccelerationSampleAt: watchAccelerationSamples
                .map(\.capturedAt).max(),
            transportEnrichmentModelVersion:
                AppleTransportContextService.enrichmentModelVersion,
            settingsHash: settings.hashValue
        )
        let latestReadingWithPoint = filteredArchivedReadings
            .filter { $0.point != nil }
            .max { $0.timestamp < $1.timestamp }
        let fingerprintUnchanged =
            sensorRefreshFingerprints[span.start] == refreshFingerprint
        if fingerprintUnchanged {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_refresh_skipped",
                fields: ["reason": "fingerprint_unchanged"]
            )
            // A restaurant can be registered after the last sensor pass. The
            // archived GPS samples are enough to backfill its meal record
            // without rebuilding the route and place lanes.
            applyRestaurantMealRecords(
                readings: filteredArchivedReadings,
                watchSummaries: watchSummaries,
                watchAccelerationSamples: watchAccelerationSamples,
                inside: span
            )
            await applyStationaryContextRecords(
                stays: snapshot.places,
                stationarySpans: motionActivities
                    .filter { $0.motion == .stationary }
                    .map(\.span),
                travel: snapshot.travel,
                readings: sensorQuality.readings,
                watchSummaries: watchSummaries,
                watchAccelerationSamples: watchAccelerationSamples,
                evidence: Self.sensorEvidenceSpan(
                    readings: archivedReadings,
                    activities: motionActivities,
                    inside: span
                ),
                inside: span
            )
            applyPlaceActivityRecords(stays: snapshot.places, inside: span)
            // Sleep inference depends on the current observation cutoff, not
            // only on new samples. Re-run it on refresh so an earlier sparse
            // pass can become valid as today's sensor window completes.
            applyChargingInactivitySleepRecords(
                readings: sleepReadings,
                inside: sleepSpan
            )
            snapshot.settings.confirmedSleepSpans =
                TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                    existing: snapshot.settings.confirmedSleepSpans,
                    corrections: snapshot.settings.activityCorrections,
                    actuals: snapshot.actuals
                )
            snapshot.actuals =
                TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
                    snapshot.settings.confirmedSleepSpans,
                    to: snapshot.actuals
                )
            guard await applyClassifiedActivityRecords(
                readings: sensorQuality.routeReadings,
                inside: span
            ) else { return false }
            applyInferredGapRecords(
                readings: sensorQuality.readings,
                travel: snapshot.travel,
                inside: span
            )
            guard (settings.locationEnabled || settings.weatherEnabled),
                  weatherNeedsRefresh(for: latestReadingWithPoint) else {
                committed = true
                return true
            }
            await refreshWeather(
                in: span,
                fallbackReading: latestReadingWithPoint
            )
            committed = true
            return true
        }
        let iPhonePedometerEvidence =
            await sensorService.pedometerEvidence(for: motionActivities)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        if !motionActivities.isEmpty {
            let existingAutomatic = snapshot.actuals.filter {
                $0.source != .motion
            }
            let generatedMotionActuals = MotionActivityActualEngine.records(
                from: motionActivities,
                existing: existingAutomatic,
                inside: span
            ).filter {
                !snapshot.settings.suppressedActualIDs.contains($0.id)
            }
            let existingMotionActuals = snapshot.actuals.filter {
                $0.source == .motion
                    && $0.modelVersion != ChargingInactivitySleepEngine.modelVersion
                    && $0.modelVersion != PhoneSleepWakeEngine.modelVersion
            }
            let mergedMotionActuals = ActivityClassificationLockEngine
                .mergingLockedClassifications(
                    existing: existingMotionActuals,
                    fresh: generatedMotionActuals,
                    inside: span
                )
            Self.integrationLogger.notice(
                "Motion history refresh: activities=\(motionActivities.count, privacy: .public), generated=\(generatedMotionActuals.count, privacy: .public), spanStart=\(span.start.timeIntervalSince1970, privacy: .public), observationEnd=\(min(span.end, Date.now).timeIntervalSince1970, privacy: .public)"
            )
            snapshot.actuals.removeAll {
                $0.source == .motion
                    && $0.modelVersion
                        != ChargingInactivitySleepEngine.modelVersion
                    && $0.modelVersion != PhoneSleepWakeEngine.modelVersion
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            snapshot.actuals.append(contentsOf: mergedMotionActuals)
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        }
        if let capturedAt = motionActivities.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .iPhoneMotion,
                kind: "motion-activities",
                payload: motionActivities,
                capturedAt: capturedAt
            )
        }
        if let pedometer {
            await archiveRawDeviceData(
                source: .iPhonePedometer,
                kind: "pedometer-summary",
                payload: pedometer,
                capturedAt: pedometer.span.end
            )
        }
        if let capturedAt = healthKitMovementEvidence.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .healthKit,
                kind: "movement-evidence",
                payload: healthKitMovementEvidence,
                capturedAt: capturedAt
            )
        }
        let healthMovementEvidence =
            iPhonePedometerEvidence + healthKitMovementEvidence
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let photoLocationReadings = photoBackfillReadings(
            in: span,
            existingReadings: archivedReadings
        )
        // 다른 앱·Apple Watch가 HealthKit에 남긴 경로로 빈 구간을 채운다.
        let healthRouteReadings: [SensorReading]
        if settings.healthEnabled {
            healthRouteReadings = HealthRouteMergeEngine.merging(
                (try? await healthService.workoutRouteReadings(in: span)) ?? [],
                into: archivedReadings
            )
        } else {
            healthRouteReadings = []
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let filteredHealthRouteReadings = TaptionRouteEngineAdapter
            .filteredReadings(
                from: healthRouteReadings,
                includeLowConfidenceBoundaries: false
            )
        if archivedReadings.isEmpty,
           photoLocationReadings.isEmpty,
           healthRouteReadings.isEmpty,
           motionActivities.isEmpty,
           healthMovementEvidence.isEmpty,
           sleepReadings.isEmpty,
           watchSummaries.isEmpty,
           watchAccelerationSamples.isEmpty {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_travel_inference_completed",
                fields: [
                    "gps_readings": String(archivedReadings.count),
                    "gps_filtered_readings": String(filteredArchivedReadings.count),
                    "health_route_readings": String(healthRouteReadings.count),
                    "motion_activities": String(motionActivities.count),
                    "places": "0",
                    "travel": "0",
                    "persisted": "false",
                    "reason": "no_evidence",
                ]
            )
            sensorRefreshFingerprints[span.start] = refreshFingerprint
            committed = true
            return true
        }

        var readings = AppleDeviceGroundTruthEngine
            .applyingMotionHistory(
                to: (
                    filteredArchivedReadings
                        + photoLocationReadings
                        + filteredHealthRouteReadings
                ).filter { RouteTimelineTimestamp.isValid($0.timestamp) }
                    .sorted { $0.timestamp < $1.timestamp },
                activities: motionActivities
            )
        readings = await transportContextService.enriching(
            readings,
            userTransitLocations: settings.userTransitLocations
        )
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let knownPlaces = snapshot.places
        let knownNames = knownPlaces.reduce(into: [String: String]()) {
            $0[$1.placeKey] = $1.displayName
        }
        var detectedPlaces = PlaceDetectionEngine().detectStays(
            readings: readings,
            knownNames: knownNames
        )
        for index in detectedPlaces.indices
            where detectedPlaces[index].displayName == "자동 감지 장소" {
            guard !Task.isCancelled, acceptsDataMutation() else { return false }
            guard let point = detectedPlaces[index].point,
                  let name = await placeNameResolver.displayName(
                      latitude: point.latitude,
                      longitude: point.longitude
                  ) else {
                continue
            }
            detectedPlaces[index].displayName = name
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }

        detectedPlaces = FrequentPlaceResolutionEngine().applying(
            settings.frequentPlaces,
            to: detectedPlaces,
            readings: readings
        )

        let floorTimeline = FloorTimelineEngine().apply(
            readings: readings,
            to: detectedPlaces,
            knownPlaces: knownPlaces
        )
        let basePlaces = floorTimeline.places
        let walkingLocations = WalkingLocationEngine()
            .build(readings: readings)
            .filter { walkingLocation in
                !basePlaces.contains { place in
                    guard let placePoint = place.point,
                          let walkingPoint = walkingLocation.point,
                          place.span.intersection(
                              with: walkingLocation.span
                          ) != nil else {
                        return false
                    }
                    return distanceMeters(placePoint, walkingPoint) <= 100
                }
            }
        let places = basePlaces + walkingLocations
        let floors = floorTimeline.transitions
        let gpsSegments = MovementRouteBuilder().build(
            stays: basePlaces,
            readings: readings,
            healthEvidence: healthMovementEvidence,
            userTransitLocations: settings.userTransitLocations
        )
        let previousSubwaySegments = snapshot.travel.filter {
            $0.mode == .subway
                && $0.span.intersection(with: span) != nil
        }
        let inferredTravel = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: motionActivities,
            pedometer: pedometer,
            healthEvidence: healthMovementEvidence,
            readings: readings,
            preservedSubwaySegments: previousSubwaySegments,
            userTransitLocations: settings.userTransitLocations
        )
        let correctedTravel = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            AppleDeviceGroundTruthEngine.enforcingMotionFamily(
                MovementCorrectionEngine.applying(
                    snapshot.settings.movementCorrections,
                    to: inferredTravel,
                    places: basePlaces
                ),
                activities: motionActivities,
                readings: readings
            )
        )
        let generatedTravel = AppleDeviceGroundTruthEngine.coalescingTravel(
            TransitBoardingDecisionEngine.applying(
                snapshot.settings.transitBoardingDecisions,
                to: correctedTravel
            ),
            stays: basePlaces,
            maximumGap: max(
                5 * 60,
                snapshot.settings.sensorCollectionProfile.interval + 60
            )
        )
        let travel = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: snapshot.travel,
            fresh: generatedTravel,
            inside: span
        )

        // A photo location is only a fallback anchor. It must not erase a
        // previously recorded route when the sensor archive is temporarily
        // unavailable. HealthKit workout routes are valid primary evidence.
        let hasPrimaryLocationEvidence = !filteredArchivedReadings.isEmpty
            || !filteredHealthRouteReadings.isEmpty
        var travelDiagnostics =
            TaptionPlanDiagnosticsTravelSummary.fields(for: travel)
        travelDiagnostics["gps_readings"] = String(archivedReadings.count)
        travelDiagnostics["health_route_readings"] = String(
            healthRouteReadings.count
        )
        travelDiagnostics["motion_activities"] = String(
            motionActivities.count
        )
        travelDiagnostics["places"] = String(places.count)
        travelDiagnostics["base_places"] = String(basePlaces.count)
        travelDiagnostics["persisted"] = String(hasPrimaryLocationEvidence)
        let subwayCount = travel.filter { $0.mode == .subway }.count
        if !previousSubwaySegments.isEmpty,
           subwayCount > 0 {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_subway_stabilized",
                fields: [
                    "previous": String(previousSubwaySegments.count),
                    "current": String(subwayCount),
                ]
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_travel_inference_completed",
            fields: travelDiagnostics
        )

        if hasPrimaryLocationEvidence {
            snapshot.travel.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.append(contentsOf: places)
            snapshot.floorTransitions.append(contentsOf: floors)
            snapshot.travel.append(contentsOf: travel)
        }
        snapshot.places.sort { $0.span.start < $1.span.start }
        snapshot.travel.sort { $0.span.start < $1.span.start }
        snapshot.floorTransitions.sort { $0.span.start < $1.span.start }

        applyRestaurantMealRecords(
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        )
        // 이번 갱신에서 만든 이동과 장소를 모두 확정한 다음에 정지 구간
        // 문맥을 붙인다. 예전 이동만 보고 있으면 "대기"를 찾을 수 없었다.
        let contextStays = hasPrimaryLocationEvidence
            ? places
            : snapshot.places
        let contextTravel = hasPrimaryLocationEvidence
            ? travel
            : snapshot.travel
        await applyStationaryContextRecords(
            stays: contextStays,
            stationarySpans: motionActivities
                .filter { $0.motion == .stationary }
                .map(\.span),
            travel: contextTravel,
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            evidence: Self.sensorEvidenceSpan(
                readings: archivedReadings,
                activities: motionActivities,
                inside: span
            ),
            inside: span
        )
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        applyPlaceActivityRecords(stays: contextStays, inside: span)
        applyChargingInactivitySleepRecords(
            // Sleep inference also consumes motion-only samples that have no
            // GPS point; keep the raw sensor stream as its input.
            readings: sleepReadings,
            inside: sleepSpan
        )
        snapshot.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: snapshot.settings.confirmedSleepSpans,
                corrections: snapshot.settings.activityCorrections,
                actuals: snapshot.actuals
            )
        snapshot.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: snapshot.actuals
        )
        guard await applyClassifiedActivityRecords(
            readings: readings,
            inside: span
        ) else { return false }
        applyInferredGapRecords(
            readings: sensorQuality.readings,
            travel: snapshot.travel,
            inside: span
        )

        if snapshot.settings.locationEnabled || snapshot.settings.weatherEnabled {
            await refreshWeather(
                in: span,
                fallbackReading: latestReadingWithPoint
            )
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        sensorRefreshFingerprints[span.start] = refreshFingerprint
        committed = true
        return true
    }

    private func applyReplayedWatchSummaries(
        _ summaries: [TaptionWatchSensorSummary]
    ) {
        for summary in summaries {
            let linkedPlan = summary.linkedPlanID.flatMap { planID in
                snapshot.plans.first { $0.id == planID }
            }
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                summary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: isWatchSummaryAtHome(summary)
            )
        }
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
    }

    private func applyInferredGapRecords(
        readings: [SensorReading],
        travel: [TravelSegment],
        inside span: TimeSpan
    ) {
        let existing = snapshot.actuals.filter {
            $0.modelVersion == TaptionActivityEngineAdapter.inferredGapModelVersion
                && $0.span(asOf: span.end).intersection(with: span) != nil
        }
        let fresh = TaptionActivityEngineAdapter.inferredGapActuals(
            readings: readings,
            travel: travel,
            actuals: snapshot.actuals,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        // Sparse refreshes are not evidence that an earlier inference vanished.
        guard !fresh.isEmpty else { return }
        let merged = ActivityClassificationLockEngine
            .mergingLockedClassifications(
                existing: existing,
                fresh: fresh,
                inside: span
            )
        snapshot.actuals.removeAll {
            $0.modelVersion == TaptionActivityEngineAdapter.inferredGapModelVersion
                && $0.span(asOf: span.end).intersection(with: span) != nil
        }
        snapshot.actuals.append(contentsOf: merged)
        snapshot.actuals.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_activity_gap_inference_completed",
            fields: [
                "fresh": String(fresh.count),
                "persisted": String(merged.count),
                "model": TaptionActivityEngineAdapter.inferredGapModelVersion,
            ]
        )
    }

    private func applyClassifiedActivityRecords(
        readings: [SensorReading],
        inside span: TimeSpan
    ) async -> Bool {
        let classifiedModelVersion =
            TaptionActivityEngineAdapter.classifiedActivityModelVersion
        let revisionFence = activityClassificationRevisionFence
        return await ActivityClassificationRetry.apply(
            capture: {
                ActivityClassificationSourceSnapshot(
                    revision: snapshotRevision,
                    snapshot: snapshot
                )
            },
            currentRevision: { snapshotRevision },
            classify: { source -> ([ActualRecord], Int, Int)? in
                guard !Task.isCancelled else { return nil }
                let calculation = Task.detached(priority: .utility) {
                    () throws -> ([ActualRecord], Int, Int)? in
                    var existing: [ActualRecord] = []
                    var baseActuals: [ActualRecord] = []
                    var updatedActuals: [ActualRecord] = []
                    for (index, actual) in source.actuals.enumerated() {
                        if index.isMultiple(of: 512), Task.isCancelled { return nil }
                        let isInSpan = actual.span(asOf: span.end)
                            .intersection(with: span) != nil
                        if actual.modelVersion == classifiedModelVersion {
                            if isInSpan {
                                existing.append(actual)
                            } else {
                                updatedActuals.append(actual)
                            }
                        } else {
                            if isInSpan { baseActuals.append(actual) }
                            updatedActuals.append(actual)
                        }
                    }
                    guard !Task.isCancelled else { return nil }
                    try revisionFence.check(source.revision)
                    let fresh = try TaptionActivityEngineAdapter.classifiedActivityActuals(
                        readings: readings,
                        travel: source.travel,
                        corrections: source.corrections,
                        actuals: baseActuals,
                        inside: span,
                        cancellationCheck: {
                            try Task.checkCancellation()
                            try revisionFence.check(source.revision)
                        }
                    ).filter { !source.suppressedIDs.contains($0.id) }
                    let merged = ActivityClassificationLockEngine
                        .mergingLockedClassifications(
                            existing: existing,
                            fresh: fresh,
                            inside: span
                        )
                    updatedActuals.append(contentsOf: merged)
                    guard !Task.isCancelled else { return nil }
                    try revisionFence.check(source.revision)
                    updatedActuals = try ActivityClassificationRecordOrdering.sorted(
                        updatedActuals,
                        cancellationCheck: {
                            try Task.checkCancellation()
                            try revisionFence.check(source.revision)
                        }
                    )
                    try revisionFence.check(source.revision)
                    return (updatedActuals, fresh.count, merged.count)
                }
                let result = await withTaskCancellationHandler {
                    do {
                        return try await calculation.value
                    } catch {
                        return nil
                    }
                } onCancel: {
                    calculation.cancel()
                }
                guard !Task.isCancelled, let result, acceptsDataMutation() else {
                    return nil
                }
                return result
            },
            commit: { _, result in
                if snapshot.actuals != result.0 {
                    snapshot.actuals = result.0
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_activity_classification_completed",
                    fields: [
                        "fresh": String(result.1),
                        "persisted": String(result.2),
                        "model": classifiedModelVersion,
                    ]
                )
            }
        )
    }

    private func applyChargingInactivitySleepRecords(
        readings: [SensorReading],
        inside span: TimeSpan
    ) {
        let maximumSampleGap = max(
            20 * 60,
            settings.sensorCollectionProfile.interval * 1.6 + 60
        )
        guard !readings.isEmpty else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sleep_inference_completed",
                fields: [
                    "health_enabled": String(settings.healthEnabled),
                    "home_point": String(
                        settings.frequentPlaces.contains {
                            $0.kind == .home
                                && $0.isAutomaticRecordingEnabled
                                && $0.point != nil
                        }
                    ),
                    "readings": "0",
                    "records": "0",
                    "reason": "no_readings",
                ]
            )
            return
        }
        let evidenceSpan = TimeSpan(
            start: readings.map(\.timestamp).min() ?? span.start,
            end: readings.map(\.timestamp).max() ?? span.start
        )
        let homePoint = settings.frequentPlaces.first {
            $0.kind == .home && $0.isAutomaticRecordingEnabled
        }?.point
        let strictRecords = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: snapshot.actuals,
            inside: span,
            homePoint: homePoint,
            maximumSampleGap: maximumSampleGap,
            authoritativeSleepSpans: sleepSessions.compactMap {
                $0.span.intersection(with: span)
            }
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let fallbackRecords: [ActualRecord]
        if strictRecords.isEmpty {
            fallbackRecords = PhoneSleepFallbackEngine.records(
                readings: readings,
                actuals: snapshot.actuals,
                inside: span,
                nominalMaximumSampleGap: maximumSampleGap,
                authoritativeSleepSpans: sleepSessions.map(\.span)
            ).filter {
                !snapshot.settings.suppressedActualIDs.contains($0.id)
            }
        } else {
            fallbackRecords = []
        }
        let records = strictRecords + fallbackRecords
        let ordered = readings
            .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        let largeGapCount = zip(ordered, ordered.dropFirst()).filter {
            $1.timestamp.timeIntervalSince($0.timestamp) > maximumSampleGap
        }.count
        TaptionPlanDiagnosticsLogger.shared.record(
            "sleep_inference_completed",
            fields: [
                "charging": String(readings.filter {
                    $0.powerState?.isCharging == true
                }.count),
                "first": String(evidenceSpan.start.timeIntervalSince1970),
                "engine": strictRecords.isEmpty
                    ? (fallbackRecords.isEmpty ? "none" : "iphone-fallback")
                    : "strict",
                "health_enabled": String(settings.healthEnabled),
                "home_point": String(homePoint != nil),
                "large_gaps": String(largeGapCount),
                "max_gap_seconds": String(Int(zip(ordered, ordered.dropFirst()).map {
                    $1.timestamp.timeIntervalSince($0.timestamp)
                }.max() ?? 0)),
                "stationary": String(ordered.filter { $0.motion == .stationary }.count),
                "stationary_dark": String(ordered.filter {
                    $0.motion == .stationary && $0.screenIsOn == false
                }.count),
                "last": String(evidenceSpan.end.timeIntervalSince1970),
                "readings": String(readings.count),
                "records": String(records.count),
                "reason": records.isEmpty
                    ? "conditions_or_continuity_not_met"
                    : "recorded",
                "strict_records": String(strictRecords.count),
                "fallback_records": String(fallbackRecords.count),
                "screen_missing": String(readings.filter {
                    $0.screenIsOn == nil
                }.count),
                "screen_off": String(readings.filter {
                    $0.screenIsOn == false
                }.count),
                "screen_on": String(readings.filter {
                    $0.screenIsOn == true
                }.count),
            ]
        )
        snapshot.actuals.removeAll { actual in
            (actual.modelVersion == ChargingInactivitySleepEngine.modelVersion
                || actual.modelVersion == PhoneSleepWakeEngine.modelVersion)
                && actual.span(asOf: span.end)
                    .intersection(with: evidenceSpan) != nil
        }
        snapshot.actuals.removeAll { actual in
            actual.modelVersion == TaptionActivityEngineAdapter.strictSleepModelVersion
                && actual.span(asOf: span.end)
                    .intersection(with: evidenceSpan) != nil
        }
        snapshot.actuals.append(contentsOf: records)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    func setWeatherEnabled(_ enabled: Bool) async {
        snapshot.settings.weatherEnabled = enabled
        snapshot.settings.permissions[.weather] =
            enabled ? .authorized : .denied
        if enabled {
            await refreshSensorTimeline()
        }
        await persist()
    }

    func setWeatherSidebarVisible(_ visible: Bool) {
        guard snapshot.settings.weatherSidebarVisible != visible else { return }
        snapshot.settings.weatherSidebarVisible = visible
        Task { await persist() }
    }

    func setMapDisplayStyle(_ style: MapDisplayStyle) {
        let persistedStyle = style.runtimeStyle
        guard snapshot.settings.mapDisplayStyle != persistedStyle else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_style_changed",
            fields: [
                "from": snapshot.settings.mapDisplayStyle.rawValue,
                "to": persistedStyle.rawValue,
            ]
        )
        snapshot.settings.mapDisplayStyle = persistedStyle
        Task { await persist() }
    }

    func setMapDisplayProvider(_ provider: MapDisplayProvider) {
        setMapDisplayStyle(.standard)
    }

    func setMapMemoDisplayFilter(_ filter: MapMemoDisplayFilter) {
        guard snapshot.settings.mapMemoDisplayFilter != filter else { return }
        snapshot.settings.mapMemoDisplayFilter = filter
        Task { await persist() }
    }

    @discardableResult
    func addMapSticker(
        title: String,
        memo: String? = nil,
        systemImage: String = "star.fill",
        colorHex: String = "#F28FA9",
        placement: MapStickerPlacement,
        point: GeoPoint?,
        planID: UUID?,
        occurredAt: Date
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        guard placement == .schedule || point != nil else { return nil }
        let sticker = MapSticker(
            title: cleanTitle,
            memo: cleanOptionalMapStickerMemo(memo),
            systemImage: systemImage,
            colorHex: colorHex,
            placement: placement,
            point: point,
            planID: planID,
            occurredAt: occurredAt
        )
        snapshot.stickers.append(sticker)
        Task { await persist() }
        return sticker.id
    }

    @discardableResult
    func updateMapSticker(
        _ stickerID: UUID,
        title: String,
        memo: String? = nil,
        systemImage: String,
        colorHex: String,
        placement: MapStickerPlacement,
        point: GeoPoint?,
        planID: UUID?,
        occurredAt: Date
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              placement == .schedule || point != nil,
              let index = snapshot.stickers.firstIndex(where: { $0.id == stickerID })
        else { return false }
        var sticker = snapshot.stickers[index]
        sticker.title = cleanTitle
        sticker.memo = cleanOptionalMapStickerMemo(memo)
        sticker.systemImage = systemImage
        sticker.colorHex = colorHex
        sticker.placement = placement
        sticker.point = point
        sticker.planID = planID
        sticker.occurredAt = occurredAt
        sticker.updatedAt = .now
        snapshot.stickers[index] = sticker
        Task { await persist() }
        return true
    }

    private func cleanOptionalMapStickerMemo(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanText.isEmpty ? nil : cleanText
    }

    func deleteMapSticker(_ stickerID: UUID) {
        guard acceptsDataMutation() else { return }
        guard snapshot.stickers.contains(where: { $0.id == stickerID }) else {
            return
        }
        snapshot.settings.cloudDeletedRecordKeys.insert(
            CloudBackupRecordKey.sticker(stickerID)
        )
        snapshot.stickers.removeAll { $0.id == stickerID }
        Task { await persist() }
    }

    func confirmTravel(_ travelID: UUID, mode: TravelMode) {
        confirmTravel([travelID], mode: mode)
    }

    func confirmTravel(_ travelIDs: [UUID], mode: TravelMode) {
        let ids = Set(travelIDs)
        let previousSegments = snapshot.travel.filter { ids.contains($0.id) }
        var corrections = snapshot.settings.movementCorrections
        var didChange = false
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let wasChanged = snapshot.travel[index].mode != mode
            corrections = MovementCorrectionEngine.recording(
                mode: mode,
                for: snapshot.travel[index],
                places: snapshot.places,
                existing: corrections
            )
            snapshot.travel[index].mode = mode
            snapshot.travel[index].confidence = .high
            snapshot.travel[index].isConfirmed = true
            if mode != .subway { snapshot.travel[index].subwayRoute = nil }
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
                    || (mode != .subway && $0.hasPrefix("사용자 확정 경로 ·"))
            }
            snapshot.travel[index].evidence.append(
                wasChanged ? "사용자 확인 · 수단 수정" : "사용자 확인"
            )
            didChange = true
        }
        guard didChange else { return }
        snapshot.settings.movementCorrections = corrections
        snapshot.settings.transitBoardingDecisions = TransitBoardingDecisionEngine.removingConfirmations(
            for: previousSegments, from: snapshot.settings.transitBoardingDecisions)
        snapshot.settings.predictedRouteDecisions.removeAll {
            !$0.isDeleted && $0.route.travelID.map(ids.contains) == true
        }
        Task { await persist() }
    }

    @discardableResult
    func confirmTransitBoarding(_ candidate: TransitBoardingCandidate) async -> Bool {
        await saveTransitBoardingDecision(for: candidate, mode: candidate.mode)
    }

    @discardableResult
    func savePredictedRouteDecision(_ route: MapPredictedRoute, deleting: Bool) async -> Bool {
        guard acceptsDataMutation(), route.isValid, !Task.isCancelled else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let generation = dataDeletionGeneration
        do {
            while acceptsDataMutation(), generation == dataDeletionGeneration {
                try Task.checkCancellation()
                let revision = snapshotRevision
                var value = snapshotForPersistence()
                value.settings.predictedRouteDecisions.removeAll { $0.matches(route) }
                value.settings.predictedRouteDecisions.append(.init(route: route,
                    isDeleted: deleting, updatedAt: .now))
                if !deleting, let travelID = route.travelID,
                   let index = value.travel.firstIndex(where: { $0.id == travelID }) {
                    value.travel[index].isConfirmed = true
                    value.travel[index].confidence = .high
                    let evidence = "사용자 확정 경로 · 예상 좌표 기반"
                    if !value.travel[index].evidence.contains(evidence) { value.travel[index].evidence.append(evidence) }
                }
                value.updatedAt = .now
                guard try await saveToRepository(value, expectedRevision: revision),
                      revision == snapshotRevision else { continue }
                value.memos = snapshot.memos
                snapshot = value
                schedulePostSaveRefresh()
                publishWidgetPayload()
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "경로를 저장하지 못했습니다. 다시 시도해 주세요.",
                english: "Could not save the route. Please try again."
            )
            TaptionPlanDiagnosticsLogger.shared.record("predicted_route_save_failed", level: .error,
                fields: ["action": deleting ? "delete" : "confirm", "error_type": String(describing: type(of: error))])
        }
        return false
    }

    @discardableResult
    func deleteTransitBoardingCandidate(_ candidate: TransitBoardingCandidate) async -> Bool {
        await saveTransitBoardingDecision(for: candidate, mode: nil)
    }

    private func saveTransitBoardingDecision(
        for candidate: TransitBoardingCandidate,
        mode: TravelMode?
    ) async -> Bool {
        guard acceptsDataMutation(), !Task.isCancelled else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let generation = dataDeletionGeneration
        let ids = Set(candidate.travelSegmentIDs)
        let decision = TransitBoardingDecision(
            candidateKey: candidate.id, placeID: candidate.placeID,
            kind: candidate.kind, point: candidate.point, span: candidate.span,
            mode: mode, travelSegmentIDs: candidate.travelSegmentIDs,
            subwayRoutes: mode == .subway
                ? candidate.subwayRoutes.filter { ids.contains($0.travelSegmentID) } : nil)
        do {
            // Rebase on sensor/other edits that arrive while the repository write is waiting.
            while acceptsDataMutation(), generation == dataDeletionGeneration {
                try Task.checkCancellation()
                guard mode == nil || snapshot.travel.contains(where: { ids.contains($0.id) }) else {
                    userFacingError = AppLanguagePreference.text(
                        korean: "이동 기록이 변경되었습니다. 지도의 탑승 후보를 다시 선택해 주세요.",
                        english: "The movement record has changed. Select the boarding candidate on the map again."
                    )
                    return false
                }
                let revision = snapshotRevision
                var value = snapshotForPersistence()
                if let mode {
                    for segment in value.travel where ids.contains(segment.id) {
                        value.settings.movementCorrections = MovementCorrectionEngine.recording(
                            mode: mode, for: segment,
                            places: value.places, existing: value.settings.movementCorrections)
                    }
                    value.travel = value.travel.map { segment in
                        guard ids.contains(segment.id) else { return segment }
                        return TransitBoardingDecisionEngine.applying([decision], to: [segment]).first ?? segment
                    }
                }
                value.settings.transitBoardingDecisions.removeAll {
                    $0.candidateKey == decision.candidateKey
                }
                value.settings.transitBoardingDecisions.append(decision)
                value.settings.transitBoardingDecisions.sort { $0.updatedAt < $1.updatedAt }
                if value.settings.transitBoardingDecisions.count > 200 {
                    value.settings.transitBoardingDecisions.removeFirst(
                        value.settings.transitBoardingDecisions.count - 200)
                }
                value.updatedAt = .now
                guard try await saveToRepository(value, expectedRevision: revision),
                      revision == snapshotRevision else { continue }
                value.memos = snapshot.memos
                snapshot = value
                schedulePostSaveRefresh()
                publishWidgetPayload()
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: mode == nil
                    ? "탑승 후보를 삭제하지 못했습니다. 다시 시도해 주세요."
                    : "탑승 경로를 저장하지 못했습니다. 다시 시도해 주세요.",
                english: mode == nil
                    ? "Could not delete the boarding candidate. Please try again."
                    : "Could not save the boarding route. Please try again."
            )
            TaptionPlanDiagnosticsLogger.shared.record("transit_boarding_save_failed", level: .error,
                fields: ["error": String(describing: type(of: error))])
        }
        return false
    }

    func forgetTravelConfirmation(_ travelID: UUID) {
        forgetTravelConfirmations([travelID])
    }

    func forgetTravelConfirmations(_ travelIDs: [UUID]) {
        let ids = Set(travelIDs)
        let previousSegments = snapshot.travel.filter { ids.contains($0.id) }
        var corrections = snapshot.settings.movementCorrections
        var earliestStart: Date?
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let segment = snapshot.travel[index]
            let correction = MovementCorrectionEngine.correction(
                for: segment,
                places: snapshot.places,
                in: corrections
            )
            corrections = MovementCorrectionEngine.removingCorrection(
                for: segment,
                places: snapshot.places,
                from: corrections
            )
            snapshot.travel[index].mode = correction?.inferredMode ?? segment.mode
            snapshot.travel[index].confidence =
                correction?.inferredConfidence ?? .medium
            snapshot.travel[index].isConfirmed = false
            snapshot.travel[index].subwayRoute = nil
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
                    || $0.hasPrefix("사용자 확정 경로 ·")
            }
            earliestStart = min(earliestStart ?? segment.span.start, segment.span.start)
        }
        guard let earliestStart else { return }
        snapshot.settings.movementCorrections = corrections
        snapshot.settings.transitBoardingDecisions = TransitBoardingDecisionEngine.removingConfirmations(
            for: previousSegments, from: snapshot.settings.transitBoardingDecisions)
        snapshot.settings.predictedRouteDecisions.removeAll {
            !$0.isDeleted && $0.route.travelID.map(ids.contains) == true
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: earliestStart)
            await persistDeviceLocalSnapshot()
        }
    }

    private func watchSensorTimelineData(
        in span: TimeSpan
    ) async -> WatchSensorTimelineData {
        var summaries = [String: TaptionWatchSensorSummary]()
        var chunks = [UUID: TaptionWatchAccelerationChunk]()

        if let dayDatabase {
            async let databaseSummaries = try? dayDatabase.watchSummaries(
                in: span
            )
            async let databaseChunks = try? dayDatabase.watchAccelerationChunks(
                in: span
            )
            for summary in (await databaseSummaries) ?? [] {
                summaries["\(summary.sessionID.uuidString):\(summary.sequence)"] =
                    summary
            }
            for chunk in (await databaseChunks) ?? [] {
                chunks[chunk.id] = chunk
            }
        }

        let sourceSummaries = Array(summaries.values)
        let sourceChunks = Array(chunks.values)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let orderedSummaries = try RouteTimelineCancellableSort.sorted(sourceSummaries,
                by: { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sequence < $1.sequence },
                cancellationCheck: { try Task.checkCancellation() })
            let orderedChunks = try RouteTimelineCancellableSort.sorted(sourceChunks,
                by: { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sequence < $1.sequence },
                cancellationCheck: { try Task.checkCancellation() })
            let replayed = WatchActivityRawReplayEngine.replaying(summaries: orderedSummaries, chunks: orderedChunks)
            try Task.checkCancellation()
            return WatchSensorTimelineData(summaries: replayed, accelerationChunks: orderedChunks)
        }
        guard let prepared = try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() }) else {
            return WatchSensorTimelineData(summaries: [], accelerationChunks: [])
        }
        let replayed = prepared.summaries
        let orderedChunks = prepared.accelerationChunks
        let replayedCount = replayed.filter {
            $0.behaviorModelVersion
                == WatchActivityRawReplayEngine.modelVersion
        }.count
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_day_raw_loaded",
            fields: [
                "span_start": String(span.start.timeIntervalSince1970),
                "span_end": String(span.end.timeIntervalSince1970),
                "summaries": String(replayed.count),
                "chunks": String(orderedChunks.count),
                "samples": String(orderedChunks.reduce(0) { $0 + $1.samples.count }),
                "replayed": String(replayedCount),
            ]
        )
        return WatchSensorTimelineData(
            summaries: replayed,
            accelerationChunks: orderedChunks
        )
    }

    func sensorReadingsLoadResult(
        in span: TimeSpan
    ) async -> SensorReadingsLoadResult {
        async let watchDataTask = watchSensorTimelineData(in: span)
        let archived: [SensorReading]
        let isComplete: Bool
        if let sensorService {
            do {
                let result = try await sensorService
                    .archivedRouteReadingsLoadResult(
                    in: span
                )
                archived = result.readings
                isComplete = result.isComplete
            } catch {
                let cancellationReason = Task.isCancelled ? "caller_task_cancelled"
                    : !hasCurrentDataGeneration ? "data_generation_changed" : "archive_read_failed"
                TaptionPlanDiagnosticsLogger.shared.record(
                    "route_readings_load_failed",
                    level: .error,
                    fields: [
                        "error": String(describing: type(of: error)),
                        "reason": cancellationReason,
                        "start": String(span.start.timeIntervalSince1970),
                        "end": String(span.end.timeIntervalSince1970),
                    ]
                )
                archived = []
                isComplete = false
            }
        } else {
            archived = []
            isComplete = false
        }
        let watchData = await watchDataTask
        let photoReadings = photoBackfillReadings(in: span, existingReadings: archived)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let readings = try RouteTimelineCancellableSort.sorted(
                (archived + photoReadings).filter { RouteTimelineTimestamp.isValid($0.timestamp) },
                by: { $0.timestamp < $1.timestamp }, cancellationCheck: { try Task.checkCancellation() })
            return SensorReadingsLoadResult(readings: readings, isComplete: isComplete,
                watchSummaries: watchData.summaries, watchAccelerationChunks: watchData.accelerationChunks)
        }
        return (try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })) ?? SensorReadingsLoadResult(readings: [], isComplete: false)
    }

    /// Loads the WBS-style day snapshot: one source snapshot plus one bounded
    /// sensor read. Every consumer receives derived arrays from that captured
    /// value, so an async load cannot mix two revisions or rewrite raw data.
    func planDayDataSnapshot(
        for date: Date,
        forceReload: Bool = true,
        refreshRawReadings: Bool = false
    ) async -> PlanDayDataSnapshot {
        let empty = {
            PlanDayDataSnapshot.make(
                date: date,
                sourceRevision: 0,
                source: .empty,
                sensorResult: SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            )
        }
        guard acceptsDataMutation() else { return empty() }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        if forceReload {
            await refreshSensorTimeline(containing: date)
            guard acceptsDataMutation() else { return empty() }
        }
        let sourceRevision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        if let dayLoadCoordinator {
            let fingerprint = await cachedDayFingerprint(for: date, source: source, revision: sourceRevision)
            let loaded = await dayLoadCoordinator.load(
                day: date,
                source: source,
                sourceRevision: sourceRevision,
                sourceFingerprint: fingerprint,
                sensorLoader: { [weak self] day in
                    guard let self else {
                        return SensorReadingsLoadResult(
                            readings: [],
                            isComplete: false
                        )
                    }
                    return await self.sensorReadingsLoadResult(
                        in: self.daySpan(containing: day)
                    )
                },
                forceReload: forceReload || refreshRawReadings
            )
            return acceptsDataMutation() && sourceRevision == dayProjectionRevision ? loaded : empty()
        }
        let result = await sensorReadingsLoadResult(
            in: daySpan(containing: date)
        )
        guard acceptsDataMutation(), sourceRevision == dayProjectionRevision else { return empty() }
        return PlanDayDataSnapshot.make(
            date: date,
            sourceRevision: sourceRevision,
            source: source,
            sensorResult: result
        )
    }

    func rebasePlanDayDataSnapshot(
        from previous: PlanDayDataSnapshot,
        for date: Date
    ) async -> PlanDayDataSnapshot? {
        guard acceptsDataMutation() else { return nil }
        let deletionGeneration = dataDeletionGeneration
        let sourceRevision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        let worker = Task.detached(priority: .utility) {
            try PlanDayDataSnapshot.rebase(
                from: previous,
                date: date,
                sourceRevision: sourceRevision,
                source: source,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        do {
            let rebased = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled,
                  deletionGeneration == dataDeletionGeneration,
                  sourceRevision == dayProjectionRevision, acceptsDataMutation() else { return nil }
            return rebased
        } catch {
            worker.cancel()
            return nil
        }
    }

    func planDaySourceSnapshot(for date: Date, reusing previous: PlanDayDataSnapshot?) async -> PlanDayDataSnapshot? {
        guard acceptsDataMutation() else { return nil }
        let generation = dataDeletionGeneration
        let revision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        let worker = Task.detached(priority: .utility) {
            if let previous, Calendar.autoupdatingCurrent.isDate(previous.day, inSameDayAs: date) {
                return try PlanDayDataSnapshot.rebase(from: previous, date: date,
                    sourceRevision: revision, source: source,
                    cancellationCheck: { try Task.checkCancellation() })
            }
            return try PlanDayDataSnapshot.make(date: date, sourceRevision: revision,
                source: source, sensorResult: SensorReadingsLoadResult(readings: [], isComplete: false),
                cancellationCheck: { try Task.checkCancellation() })
        }
        let value = try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })
        guard !Task.isCancelled, generation == dataDeletionGeneration,
              revision == dayProjectionRevision, acceptsDataMutation() else { return nil }
        return value
    }

    func startupDayDataPreview(for date: Date) async -> PlanDayDataSnapshot? {
        guard hasPreparedStartupSettings, !isBootstrapped, !isAppLocked,
              allowsRepositoryLoadAttempt(), let dayLoadCoordinator else { return nil }
        let generation = dataDeletionGeneration
        let value = await dayLoadCoordinator.cachedSnapshot(day: date, source: snapshot,
            sourceRevision: dayProjectionRevision)
        guard generation == dataDeletionGeneration, !isAppLocked,
              allowsRepositoryLoadAttempt() else { return nil }
        return value
    }

    func cachedPlanDayDataSnapshot(for date: Date) async -> PlanDayDataSnapshot? {
        let generation = dataDeletionGeneration
        guard acceptsDataMutation(), let dayLoadCoordinator else { return nil }
        let revision = dayProjectionRevision
        let result = await dayLoadCoordinator.cachedSnapshot(
            day: date,
            source: snapshot,
            sourceRevision: revision
        )
        guard generation == dataDeletionGeneration, revision == dayProjectionRevision, acceptsDataMutation() else {
            return nil
        }
        return result
    }

    private func indexedDaySource(_ source: TaptionDataSnapshot, for date: Date) async -> TaptionDataSnapshot {
        do {
            guard let actuals = try await repository.actuals(in: daySpan(containing: date), matching: source.actuals) else {
                return source
            }
            var value = source
            value.actuals = actuals
            return value
        } catch {
            // A failed/obsolete SQL projection must never replace in-memory edits or canonical data.
            return source
        }
    }

    private func daySpan(containing date: Date) -> TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return TimeSpan(start: start, end: end)
    }

    func rawDataRevision(for date: Date) -> UInt64 {
        _ = rawDayRevisionSignal
        return rawDayRevisions[
            Calendar.autoupdatingCurrent.startOfDay(for: date)
        ] ?? 0
    }

    func daySourceFingerprint(for date: Date) -> String? {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        if let cached = daySourceFingerprintCache.value(for: day),
           cached.revision == dayProjectionRevision {
            return cached.value
        }
        let value = PlanDayDataSnapshot.sourceFingerprint(
            date: day,
            source: snapshot
        )
        daySourceFingerprintCache.insert((dayProjectionRevision, value), for: day)
        return value
    }

    private func cachedDayFingerprint(
        for date: Date, source: TaptionDataSnapshot, revision: UInt64
    ) async -> String? {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        if let cached = daySourceFingerprintCache.value(for: day), cached.revision == revision {
            return cached.value
        }
        let worker = Task.detached(priority: .userInitiated) {
            try PlanDayDataSnapshot.sourceFingerprint(date: day, source: source,
                cancellationCheck: { try Task.checkCancellation() })
        }
        let value = await withTaskCancellationHandler(operation: {
            try? await worker.value
        }, onCancel: { worker.cancel() })
        if !Task.isCancelled, revision == dayProjectionRevision {
            daySourceFingerprintCache.insert((revision, value), for: day)
        }
        return value
    }

    private func invalidateRawDays(_ dates: [Date]) {
        let calendar = Calendar.autoupdatingCurrent
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return }
        for day in days {
            rawDayRevisions[day, default: 0] &+= 1
            dayLoadCoordinator?.invalidate(day: day)
        }
        rawDayRevisionSignal &+= 1
    }

    func sensorReadings(in span: TimeSpan) async -> [SensorReading] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: span.start)
        if dayLoadCoordinator != nil,
           let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
           span.start == dayStart,
           span.end == dayEnd {
            return await planDayDataSnapshot(
                for: dayStart,
                forceReload: false
            ).readings
        }
        return await sensorReadingsLoadResult(in: span).readings
    }

    private func photoBackfillReadings(
        in span: TimeSpan,
        existingReadings: [SensorReading]
    ) -> [SensorReading] {
        let locationGap: TimeInterval = 5 * 60
        let existingLocationTimes = existingReadings
            .filter { $0.point != nil }
            .map(\.timestamp)
        return snapshot.photos
            .filter {
                span.contains($0.capturedAt)
                    && $0.location != nil
                    && !$0.isHiddenFromTimeline
            }
            .filter { photo in
                !existingLocationTimes.contains {
                    abs($0.timeIntervalSince(photo.capturedAt)) <= locationGap
                }
            }
            .map { photo in
                SensorReading(
                    id: UUID(),
                    timestamp: photo.capturedAt,
                    point: photo.location,
                    motion: .stationary,
                    motionConfidence: .low,
                    gpsAvailable: false,
                    watchWorkoutKind: "사진 위치"
                )
            }
    }

    private func hasPhotoLocations(in span: TimeSpan) -> Bool {
        snapshot.photos.contains {
            span.contains($0.capturedAt)
                && $0.location != nil
                && !$0.isHiddenFromTimeline
        }
    }

    func confirmPlace(_ placeID: UUID, name: String, floor: Int?) {
        guard let index = snapshot.places.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.places[index].displayName = cleanName
        }
        snapshot.places[index].floor = floor
        snapshot.places[index].confidence = .high
        snapshot.places[index].isConfirmed = true
        Task { await persist() }
    }

    /// 층수를 전달하지 않은 기존 호출은 기존 기준을 유지하고, 지도 저장 UI는
    /// 사용자가 고른 층수를 기준점으로 남긴다.
    func setFrequentPlaceToCurrentLocation(_ placeID: UUID, floor: Int? = nil) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard let reading = latestSensorReading,
              reading.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        // 층수는 앱의 추정에서 가져오지 않는다. 추정이 틀린 상태에서 자리를
        // 다시 잡으면 그 틀린 층이 곧 이 건물의 기준으로 굳는다. 층은 아래
        // "이 층으로 보정"에서 사용자가 직접 확인한 값만 받는다.
        let resolvedFloor = floor
            ?? snapshot.settings.frequentPlaces[index].floor
            ?? lastManuallyConfirmedFloor(forPlaceID: placeID)
            ?? 1
        guard FloorCalibrationPrompt.range.contains(resolvedFloor) else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return
        }
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: resolvedFloor
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        updateFloorEstimate(with: reading)
        scheduleFrequentPlaceDerivedRefresh()
    }

    func setFrequentPlaceLocation(
        _ placeID: UUID,
        latitude: Double,
        longitude: Double,
        floor: Int? = nil
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return
        }
        snapshot.settings.frequentPlaces[index].setMapLocation(
            GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            )
        )
        if let floor {
            snapshot.settings.frequentPlaces[index].floor = floor
            snapshot.settings.frequentPlaces[index].floorCapturedAt = nil
        }
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        scheduleFrequentPlaceDerivedRefresh()
    }

    func clearFrequentPlaceLocation(_ placeID: UUID) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = snapshot.settings.frequentPlaces[index].point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        snapshot.settings.frequentPlaces[index].clearLocation()
        lastAutoFloorCalibrationKey = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        scheduleFrequentPlaceDerivedRefresh()
    }

    /// 장소 기준점이 바뀌면 기존 파생 기록을 같은 원본 센서 구간으로
    /// 다시 판정하고, 계산 결과까지 저장해 다음 화면·기기에서도 즉시 쓴다.
    private func scheduleFrequentPlaceDerivedRefresh() {
        let affectedDate = selectedDate
        unlockDerivedClassifications(for: affectedDate)
        liveMergeCacheKey = nil
        liveMergeCacheValue.removeAll(keepingCapacity: true)
        sensorRefreshFingerprints.removeAll()
        Task {
            await refreshSensorTimeline(containing: affectedDate)
            await persist()
        }
    }

    private func unlockDerivedClassifications(for date: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let daySpan = TimeSpan(start: dayStart, end: dayEnd)
        let sleepSpan = SleepAnalysisEngine.overnightSpan(
            containing: date,
            calendar: calendar
        )
        let affects: (TimeSpan) -> Bool = { candidate in
            candidate.intersection(with: daySpan) != nil
                || candidate.intersection(with: sleepSpan) != nil
        }
        snapshot.actuals = snapshot.actuals.map { actual in
            guard actual.source.usesAutomaticClassification,
                  !actual.manuallyCorrected,
                  affects(actual.span(asOf: max(dayEnd, sleepSpan.end))) else {
                return actual
            }
            var value = actual
            value.isClassificationLocked = false
            return value
        }
        snapshot.travel = snapshot.travel.map { segment in
            guard !segment.isConfirmed,
                  affects(segment.span) else {
                return segment
            }
            var value = segment
            value.isClassificationLocked = false
            return value
        }
    }

    /// 스테퍼가 미리 채울 값. 앱이 추정한 층은 절대 쓰지 않는다. 고치려는
    /// 값이 곧 기본값이 되면 사용자는 틀린 층을 그대로 확인하게 된다.
    /// 사용자가 직접 확인한 기준점이 없으면 미리 채울 값도 없다. 이력에 남은
    /// 옛 "수동" 기록은 이 화면이 추정값을 미리 채워 주던 시절의 것이라
    /// 사용자가 골랐다고 믿을 수 없다.
    func lastManuallyConfirmedFloor(forPlaceID placeID: UUID) -> Int? {
        settings.frequentPlaces
            .first { $0.id == placeID }?
            .floorReferencePoints
            .last(where: \.isManual)?
            .floor
    }

    /// 사용자가 "지금 이 층"이라고 알려 주면 그 자리의 기압을 이 장소의
    /// 기준으로 삼는다. 층 높이는 묻지 않는다. 서로 다른 층 기준이 둘 이상
    /// 모이면 `FrequentPlace.calibrateCurrentFloor` 가 그 차이로 구한다.
    ///
    /// 기압계 한 표본은 흔들린다. 그 한 번으로 영구 기준을 박으면 흔들림이
    /// 이 건물의 모든 층 추정에 남으므로, 짧은 묶음을 모아 중앙값으로 줄인
    /// 뒤에만 기록한다. 묶음이 모자라거나 흔들리면 아무것도 남기지 않는다.
    func calibrateFrequentPlaceFloor(_ placeID: UUID, floor: Int) async {
        guard snapshot.settings.frequentPlaces.contains(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard latestSensorReading?.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        guard let sensorService else { return }
        guard floorCalibrationSampling == nil else { return }
        floorCalibrationSampling = FloorCalibrationSampling(
            placeID: placeID,
            floor: floor,
            collected: 0,
            target: AltitudeBurstReducer.requestedSampleCount
        )
        let samples = await sensorService.captureAltitudeBurst { collected in
            self.floorCalibrationSampling?.collected = collected
        }
        floorCalibrationSampling = nil
        // 사용자가 화면을 떠났으면 조용히 접는다. 절반만 잰 값으로 기준을
        // 남기지도, 뒤늦게 오류를 띄우지도 않는다.
        guard !Task.isCancelled else { return }
        guard let anchor = latestSensorReading, anchor.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        switch AltitudeBurstReducer.reduce(samples) {
        case let .tooFewSamples(collected):
            userFacingError = AppLanguagePreference.text(
                korean: collected == 0
                    ? "기압 센서를 읽지 못해 보정을 취소했습니다. 위치 기록을 켠 뒤 다시 시도해 주세요."
                    : "표본이 \(collected)개뿐이라 보정을 취소했습니다. 잠시 후 다시 시도해 주세요.",
                english: collected == 0
                    ? "Calibration was cancelled because the barometer could not be read. Turn on location recording and try again."
                    : "Calibration was cancelled because only \(collected) samples were collected. Try again shortly."
            )
        case let .tooNoisy(spread):
            userFacingError = String(
                format: AppLanguagePreference.text(
                    korean: "고도가 %.1fm나 흔들려 보정을 취소했습니다. 한자리에 선 채로 다시 시도해 주세요.",
                    english: "Altitude fluctuated by %.1f m, so calibration was cancelled. Stay in one place and try again."
                ),
                spread
            )
        case let .reduced(sample, _):
            commitFloorCalibration(
                placeID,
                floor: floor,
                reading: anchor.replacingAltitude(with: sample)
            )
        }
    }

    private func commitFloorCalibration(
        _ placeID: UUID,
        floor: Int,
        reading: SensorReading
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].calibrateCurrentFloor(
            to: floor,
            from: reading
        )
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: reading.point?.altitude,
                isAutomatic: false,
                capturedAt: reading.timestamp
            )
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        // 기준이 바뀌면 직전 고도와의 연속성 판정은 무효다. 새 기준의 첫
        // 추정이 스파이크로 걸리면 화면이 옛 층에 그대로 머문다.
        altitudeGatePlaceID = nil
        updateFloorEstimate(with: reading)
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 잘못 들어간 기준점 하나를 지운다. 이 장소의 위치와 나머지 기준은
    /// 그대로 둔다.
    func deleteFrequentPlaceFloorReference(_ placeID: UUID, floor: Int) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }), snapshot.settings.frequentPlaces[index].removeFloorReference(
            floor: floor
        ) else {
            return
        }
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        altitudeGatePlaceID = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 기준점을 고치면 그 기준으로 매긴 지난 기록도 다시 매겨야 한다. 원본
    /// 표본은 그대로 두고 파생된 층수만 다시 구한다. 기록이 스스로 근거를
    /// 지녔으면 보관 기간과 무관하게 다시 매기고, 옛 기록은 7일 보관분과
    /// 기록에 남은 대표 GPS 고도 순으로 보완한다.
    func reapplyStoredFloors(forPlaceID placeID: UUID) async {
        guard let place = settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        let legacy = snapshot.places.filter {
            $0.placeKey == place.stablePlaceKey && $0.floorEvidence == nil
        }
        var readings: [SensorReading] = []
        if let sensorService,
           let start = legacy.map(\.span.start).min(),
           let end = legacy.map(\.span.end).max() {
            readings = (try? await sensorService.archivedReadings(
                in: TimeSpan(start: start, end: end)
            )) ?? []
        }
        let engine = FrequentPlaceResolutionEngine()
        let recomputedPlaces = engine.reapplyingFloors(
            of: place,
            to: snapshot.places,
            readings: readings
        )
        let recomputedTransitions = engine.reapplyingFloors(
            of: place,
            to: snapshot.floorTransitions
        )
        var changed = false
        if recomputedPlaces != snapshot.places {
            snapshot.places = recomputedPlaces
            changed = true
        }
        if recomputedTransitions != snapshot.floorTransitions {
            snapshot.floorTransitions = recomputedTransitions
            changed = true
        }
        guard changed else { return }
        await persist()
    }

    private func appendFloorCalibrationEvent(_ event: FloorCalibrationEvent) {
        snapshot.settings.floorCalibrationHistory.append(event)
        let overflow = snapshot.settings.floorCalibrationHistory.count - 100
        if overflow > 0 {
            snapshot.settings.floorCalibrationHistory.removeFirst(overflow)
        }
    }

    /// 자동 층 보정은 사용자 조작 없이 이 경로로만 쌓인다.
    @discardableResult
    private func recordFloorCalibration(
        placeID: UUID,
        floor: Int,
        reading: SensorReading,
        seaLevelAltitudeMeters: Double?
    ) -> Bool {
        guard reading.point != nil,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.id == placeID
              }) else {
            return false
        }
        // 사용자가 확인한 기준과 같은 높이를 다른 층이라고 주장하는 자동
        // 보정은 거절된다. 그때는 이력도 알림도 남기지 않는다.
        guard snapshot.settings.frequentPlaces[index].addFloorCalibration(
            from: reading,
            floor: floor
        ) else {
            return false
        }
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: seaLevelAltitudeMeters,
                isAutomatic: true,
                capturedAt: reading.timestamp
            )
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return true
    }

    private func showFloorCalibrationNotice(_ text: String) {
        calibrationNoticeTask?.cancel()
        floorCalibrationNotice = text
        calibrationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.floorCalibrationNotice = nil
        }
    }

    /// 자주가는 곳의 이름과 감지 범위를 저장합니다. 건물의 층 높이는 여기서
    /// 받지 않습니다. 사용자가 알려 준 현재 층수에서 앱이 직접 구합니다.
    func updateFrequentPlaceDetails(
        _ placeID: UUID,
        name: String,
        radiusMeters: Double,
        minimumDwellMinutes: Int,
        isAutomaticRecordingEnabled: Bool
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.settings.frequentPlaces[index].name = cleanName
        }
        snapshot.settings.frequentPlaces[index].radiusMeters = min(
            max(radiusMeters, 30),
            500
        )
        let minimumDwell = snapshot.settings.frequentPlaces[index].kind == .restaurant
            ? 15
            : minimumDwellMinutes
        snapshot.settings.frequentPlaces[index].minimumDwellMinutes = min(
            max(minimumDwell, 1),
            240
        )
        snapshot.settings.frequentPlaces[index]
            .isAutomaticRecordingEnabled = isAutomaticRecordingEnabled
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func addCustomFrequentPlace(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "장소 이름을 입력해 주세요.",
                english: "Enter a place name."
            )
            return
        }
        guard !snapshot.settings.frequentPlaces.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 자주가는 곳이 이미 있습니다.",
                english: "A frequent place with the same name already exists."
            )
            return
        }
        snapshot.settings.frequentPlaces.append(
            FrequentPlace(kind: .custom, name: cleanName)
        )
        Task { await persist() }
    }

    /// 식당은 이름·좌표·반경을 독립적으로 여러 곳 저장할 수 있는 자주가는
    /// 곳 유형입니다. 체류를 식사로 바꾸는 기준은 위치 분석의 15분 이상
    /// 체류로 고정하고, 이 목록은 기존 장소 영속화 경로를 함께 사용합니다.
    func addRestaurant(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "식당 이름을 입력해 주세요.",
                english: "Enter a restaurant name."
            )
            return
        }
        guard !snapshot.settings.frequentPlaces.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 자주가는 곳이 이미 있습니다.",
                english: "A frequent place with the same name already exists."
            )
            return
        }
        snapshot.settings.frequentPlaces.append(
            FrequentPlace(
                kind: .restaurant,
                name: cleanName,
                minimumDwellMinutes: 15
            )
        )
        Task { await persist() }
    }

    @discardableResult
    func addUserTransitLocation(
        name: String,
        kind: UserTransitLocationKind,
        latitude: Double,
        longitude: Double,
        floor: Int? = nil
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 이름을 입력해 주세요.",
                english: "Enter a location name."
            )
            return nil
        }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 좌표를 확인해 주세요.",
                english: "Check the location coordinates."
            )
            return nil
        }
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return nil
        }
        let location = UserTransitLocation(
            name: cleanName,
            kind: kind,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            ),
            floor: floor
        )
        snapshot.settings.userTransitLocations.append(location)
        Task { await persist() }
        return location.id
    }

    func deleteUserTransitLocation(_ id: UUID) {
        snapshot.settings.userTransitLocations.removeAll { $0.id == id }
        Task { await persist() }
    }

    func renameUserTransitLocation(_ locationID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = snapshot.settings.userTransitLocations.firstIndex(
                  where: { $0.id == locationID }
              ) else {
            return
        }
        snapshot.settings.userTransitLocations[index].name = cleanName
        Task { await persist() }
    }

    func setUserTransitLocationFloor(_ locationID: UUID, floor: Int?) {
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true,
              let index = snapshot.settings.userTransitLocations.firstIndex(
                  where: { $0.id == locationID }
              ) else {
            return
        }
        guard snapshot.settings.userTransitLocations[index].floor != floor else {
            return
        }
        snapshot.settings.userTransitLocations[index].floor = floor
        Task { await persist() }
    }

    func renameFrequentPlace(_ placeID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].name = cleanName
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func deleteFrequentPlace(_ placeID: UUID) {
        guard let target = snapshot.settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = target.point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        guard target.kind == .custom || target.kind == .restaurant else {
            snapshot.settings.frequentPlaces =
                snapshot.settings.frequentPlaces.map { place in
                    guard place.id == placeID else { return place }
                    return FrequentPlace(kind: place.kind)
                }
            Task { await persist() }
            return
        }
        snapshot.settings.frequentPlaces.removeAll { $0.id == placeID }
        Task { await persist() }
    }

    // MARK: - 등록하지 않은 자주 가는 곳

    /// 설정 화면을 열 때만 다시 구한다. 저장된 체류만 읽으므로 새 위치 수집도,
    /// 새 권한도 필요 없다.
    func refreshFrequentPlaceSuggestion() {
        frequentPlaceSuggestion = UnregisteredPlaceSuggestionEngine()
            .suggestion(
                places: snapshot.places,
                frequentPlaces: snapshot.settings.frequentPlaces,
                dismissed: snapshot.settings.dismissedPlaceSuggestions
            )
    }

    /// 제안한 자리를 사용자가 고른 종류로 등록한다. 좌표는 이미 모은 체류에서
    /// 나오므로 사용자는 종류만 고르면 된다. 이름과 반경은 이어서 열리는 기존
    /// 설정 화면에서 고친다.
    @discardableResult
    func registerFrequentPlaceSuggestion(
        as kind: FrequentPlaceKind
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let suggestion = frequentPlaceSuggestion else { return nil }
        let reading = SensorReading(
            timestamp: suggestion.lastVisitedAt,
            point: suggestion.point
        )
        let index: Int
        if kind != .custom, kind != .restaurant,
           let empty = snapshot.settings.frequentPlaces.firstIndex(where: {
               $0.kind == kind && $0.point == nil
           }) {
            index = empty
        } else {
            // 이름을 지어내지 않는다. 역지오코딩이 붙여 준 이름이 없으면
            // 좌표를 그대로 넣고 사용자가 고치게 둔다.
            snapshot.settings.frequentPlaces.append(
                FrequentPlace(
                    kind: kind,
                    name: suggestion.suggestedName
                        ?? Self.coordinateLabel(suggestion.point)
                )
            )
            index = snapshot.settings.frequentPlaces.count - 1
        }
        let floor = snapshot.settings.frequentPlaces[index].floor ?? 1
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: floor
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        let placeID = snapshot.settings.frequentPlaces[index].id
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        frequentPlaceSuggestion = nil
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return placeID
    }

    /// 거절은 영구히 기억한다. 같은 곳을 매주 다시 묻는 것이 한 번도 묻지
    /// 않는 것보다 나쁘다.
    func dismissFrequentPlaceSuggestion() {
        guard let suggestion = frequentPlaceSuggestion else { return }
        rememberDismissedPlaceSuggestion(at: suggestion.point)
        frequentPlaceSuggestion = nil
        Task { await persist() }
    }

    static func coordinateLabel(_ point: GeoPoint) -> String {
        String(
            format: "%.5f, %.5f",
            point.latitude,
            point.longitude
        )
    }

    /// 자주가는 곳에서 지운 자리도 같은 목록에 넣는다. 지우자마자 "등록할
    /// 까요?"가 다시 뜨면 지운 것이 지워지지 않은 셈이다.
    private func rememberDismissedPlaceSuggestion(at point: GeoPoint) {
        let radius = UnregisteredPlaceSuggestionEngine().dismissalRadiusMeters
        guard !snapshot.settings.dismissedPlaceSuggestions.contains(where: {
            distanceMeters($0.point, point) <= radius
        }) else {
            return
        }
        snapshot.settings.dismissedPlaceSuggestions.append(
            DismissedPlaceSuggestion(point: point)
        )
        if let suggestion = frequentPlaceSuggestion,
           distanceMeters(suggestion.point, point) <= radius {
            frequentPlaceSuggestion = nil
        }
    }

    func confirmFloorTransition(
        _ transitionID: UUID,
        toFloor: Int?
    ) {
        guard let index = snapshot.floorTransitions.firstIndex(where: {
            $0.id == transitionID
        }) else {
            return
        }
        snapshot.floorTransitions[index].toFloor = toFloor
        snapshot.floorTransitions[index].confidence = .high
        if !snapshot.floorTransitions[index].isUserConfirmed {
            snapshot.floorTransitions[index].evidence.append(
                FloorTransition.userConfirmedEvidence
            )
        }
        if let toFloor,
           let placeIndex = snapshot.places.firstIndex(where: {
               $0.placeKey == snapshot.floorTransitions[index].placeKey
                   && $0.span.contains(
                       snapshot.floorTransitions[index].span.end
                   )
           }) {
            snapshot.places[placeIndex].floor = toFloor
            snapshot.places[placeIndex].confidence = .high
            snapshot.places[placeIndex].isConfirmed = true
        }
        Task { await persist() }
    }

    func photoThumbnailData(
        localIdentifier: String,
        size: CGSize
    ) async throws -> Data {
        try await photoService.thumbnailJPEG(
            localIdentifier: localIdentifier,
            size: size
        )
    }

    func clearError() {
        userFacingError = nil
    }

    private func refreshPermissionStates() async {
        let generation = dataDeletionGeneration
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        var healthState = PermissionState.unavailable
        do {
            healthState = try await healthService.authorizationRequestState()
        } catch {
            healthState = healthService.permissionState()
        }
        guard !Task.isCancelled, dataDeletionGeneration == generation,
              acceptsDataMutation() else { return }
        let availability = await sensorService?.hardwareAvailability()
        let notificationState = await notificationScheduler.authorizationState()
        guard !Task.isCancelled, dataDeletionGeneration == generation,
              acceptsDataMutation() else { return }
        if let sensorService, !sensorService.locationPermissionState().isGranted {
            await sensorService.stopCollectionAndWait()
            guard !Task.isCancelled, dataDeletionGeneration == generation,
                  acceptsDataMutation() else { return }
        }

        let photoState = photoService.permissionState()
        let calendarState = calendarService.permissionState()
        let locationState = sensorService?.locationPermissionState() ?? .unavailable
        var updatedSettings = snapshot.settings
        let previousCalendarState = updatedSettings.permissions[.calendar] ?? .notDetermined
        updatedSettings.permissions[.photos] = photoState
        updatedSettings.permissions[.calendar] = calendarState
        updatedSettings.permissions[.health] = healthState
        updatedSettings.permissions[.location] = locationState
        updatedSettings.permissions[.motion] = sensorService?.motionPermissionState() ?? .unavailable
        updatedSettings.permissions[.notifications] = notificationState
        if !photoState.isGranted {
            updatedSettings.showsPhotos = false
            updatedSettings.showsPhotosInWidgets = false
            if !snapshot.photos.isEmpty { snapshot.photos = [] }
        }
        if calendarState.isGranted, !previousCalendarState.isGranted {
            UserDefaults.standard.removeObject(forKey: Self.calendarAutomaticRefreshKey)
            if updatedSettings.selectedCalendarIDs.isEmpty {
                updatedSettings.selectedCalendarIDs = calendarService.calendars().map(\.id)
            }
        } else if !calendarState.isGranted {
            calendarStoreRefreshTask?.cancel()
            calendarStoreRefreshTask = nil
            calendarStoreRefreshRequiresWide = false
            if !snapshot.calendarEvents.isEmpty { snapshot.calendarEvents = [] }
        }
        if healthState == .authorized {
            UserDefaults.standard.set(true, forKey: Self.healthAuthorizationRequestedKey)
        }
        if let availability, sensorAvailability != availability {
            sensorAvailability = availability
        }
        if let sensorService {
            if locationState.isGranted {
                updatedSettings.locationEnabled = true
                updatedSettings.backgroundPreciseLocationEnabled = sensorService.hasAlwaysLocationAuthorization()
            } else {
                sensorBackgroundCoordinator.cancel()
                syncSensorBackgroundState()
                if isSensorCollecting { isSensorCollecting = false }
                updatedSettings.backgroundPreciseLocationEnabled = false
            }
        } else {
            if sensorStorageErrorDescription == nil { updatedSettings.locationEnabled = false }
            updatedSettings.backgroundPreciseLocationEnabled = false
        }
        if !notificationState.isGranted { updatedSettings.notificationsEnabled = false }
        migratePermissionFlagsIfNeeded(
            settings: &updatedSettings,
            photos: photoState, calendar: calendarState, health: healthState,
            location: locationState, notifications: notificationState
        )
        if updatedSettings != snapshot.settings { snapshot.settings = updatedSettings }
    }

    private func migratePermissionFlagsIfNeeded(
        settings: inout AppFeatureSettings,
        photos: PermissionState,
        calendar: PermissionState,
        health: PermissionState,
        location: PermissionState,
        notifications: PermissionState
    ) {
        guard !UserDefaults.standard.bool(forKey: Self.permissionFlagsMigrationKey)
        else { return }
        let granted = [photos, calendar, health, location, notifications]
            .contains(where: \.isGranted)
        guard granted else { return }
        settings.showsPhotos = photos.isGranted
        settings.healthEnabled = health.isGranted
        settings.locationEnabled = location.isGranted
        settings.notificationsEnabled = notifications.isGranted
        if calendar.isGranted, settings.selectedCalendarIDs.isEmpty {
            settings.selectedCalendarIDs = calendarService.calendars().map(\.id)
        }
        UserDefaults.standard.set(true, forKey: Self.permissionFlagsMigrationKey)
    }

    private func refreshPhotos() {
        let span = visibleDataSpan
        replacePhotos(photoService.moments(in: span), in: span)
    }

    private func replacePhotos(_ fresh: [PhotoMoment], in span: TimeSpan) {
        snapshot.photos.removeAll { span.contains($0.capturedAt) }
        snapshot.photos.append(contentsOf: fresh)
        snapshot.photos.sort { $0.capturedAt < $1.capturedAt }
    }

    private func refreshCalendarEvents() async {
        await refreshCalendarEvents(in: visibleDataSpan)
    }

    func scheduleCalendarStoreRefresh(forceWide: Bool = false) {
        guard isBootstrapped,
              isSceneActive,
              permissionState(for: .calendar).isGranted,
              !snapshot.settings.selectedCalendarIDs.isEmpty else { return }
        calendarStoreRefreshRequiresWide =
            calendarStoreRefreshRequiresWide || forceWide
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  let self,
                  self.isSceneActive,
                  self.permissionState(for: .calendar).isGranted,
                  !self.snapshot.settings.selectedCalendarIDs.isEmpty else {
                return
            }
            let forceWide = self.calendarStoreRefreshRequiresWide
            self.calendarStoreRefreshRequiresWide = false
            let now = Date.now
            let lastAutomaticRefresh = UserDefaults.standard.object(
                forKey: Self.calendarAutomaticRefreshKey
            ) as? Date
            let refreshesAutomaticRange =
                CalendarSyncPolicy.shouldRefreshAutomaticRange(
                    lastRefresh: lastAutomaticRefresh,
                    now: now,
                    force: forceWide
                )
            let spans = CalendarSyncPolicy.refreshSpans(
                requested: self.visibleDataSpan,
                includesCurrentDeviceDay: true,
                refreshesAutomaticRange: refreshesAutomaticRange,
                now: now
            )
            var completed = false
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self.isSceneActive else { return }
                }
                completed = true
                for span in spans {
                    completed = await self.refreshCalendarEvents(in: span)
                        && completed
                }
                if completed { break }
            }
            if refreshesAutomaticRange, completed {
                UserDefaults.standard.set(
                    now,
                    forKey: Self.calendarAutomaticRefreshKey
                )
            }
            await self.persistDeviceLocalSnapshot()
        }
    }

    @discardableResult
    private func refreshCalendarEvents(in span: TimeSpan) async -> Bool {
        snapshot.calendarEvents = snapshot.calendarEvents.map {
            $0.normalizedForDisplay()
        }
        guard !snapshot.settings.selectedCalendarIDs.isEmpty else { return false }
        let liveCalendarIDs = calendarService.calendars().map(\.id)
        guard !liveCalendarIDs.isEmpty else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_empty_store",
                level: .notice
            )
            return false
        }
        let reconciledCalendarIDs = CalendarSyncPolicy.reconciledCalendarIDs(
            existing: snapshot.settings.selectedCalendarIDs,
            live: liveCalendarIDs
        )
        let liveIDs = Set(liveCalendarIDs)
        guard CalendarSyncPolicy.hasCompleteSelection(
            selected: Set(reconciledCalendarIDs),
            live: liveIDs
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_partial_store",
                level: .notice
            )
            return false
        }
        snapshot.settings.selectedCalendarIDs = reconciledCalendarIDs
        let selected = Set(reconciledCalendarIDs)
        guard let fresh = await calendarService.events(
            in: span,
            selectedCalendarIDs: selected
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_background_store",
                level: .notice
            )
            return false
        }
        guard !Task.isCancelled,
              permissionState(for: .calendar).isGranted,
              Set(snapshot.settings.selectedCalendarIDs) == selected else {
            return false
        }
        snapshot.calendarEvents = CalendarSyncPolicy.mergingEvents(
            existing: snapshot.calendarEvents,
            fresh: fresh,
            in: span,
            liveCalendarIDs: liveIDs
        )
        return true
    }

    private func refreshHealthData(
        in requestedSpan: TimeSpan? = nil,
        showErrors: Bool = true,
        forceRawSync: Bool = false
    ) async {
        guard acceptsDataMutation(), !isHealthRefreshRunning else { return }
        isHealthRefreshRunning = true
        defer { isHealthRefreshRunning = false }
        let span = requestedSpan ?? recentHealthSpan
        let healthFields = [
            "periodic": String(requestedSpan != nil),
            "start": String(Int(span.start.timeIntervalSince1970)),
            "end": String(Int(span.end.timeIntervalSince1970)),
        ]
        TaptionPlanDiagnosticsLogger.shared.record(
            "health_refresh_started",
            fields: healthFields
        )

        do {
            do {
                healthSyncOverview = try await healthService
                    .synchronizeChanges(force: forceRawSync)
            } catch {
                Self.integrationLogger.error(
                    "HealthKit incremental raw sync failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            async let nonSleepActualValues = healthService.nonSleepActuals(
                in: span
            )
            async let sessions = healthService.sleepSessions(in: span)
            async let importedValues = healthService.importedActuals(in: span)
            let freshSessions = try await sessions
            let directActuals = try await nonSleepActualValues
                + healthService.sleepActuals(from: freshSessions)
            let importedActuals = (try? await importedValues) ?? []
            var actualsByID = importedActuals.reduce(
                into: [UUID: ActualRecord]()
            ) { result, actual in
                result[actual.id] = actual
            }
            for actual in directActuals {
                actualsByID[actual.id] = actual
            }
            let freshActuals = actualsByID.values.sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let visibleFreshActuals = ActualRecordSuppressionEngine
                .visibleRecords(
                    from: freshActuals,
                    suppressedIDs: snapshot.settings.suppressedActualIDs
                )
                .map { actual in
                    guard actual.categoryID == "sleep"
                        || actual.title.localizedCaseInsensitiveContains("수면")
                        || actual.title.localizedCaseInsensitiveContains("sleep") else {
                        return actual
                    }
                    var value = actual
                    value.behavior = WatchBehaviorKind.sleep.rawValue
                    value.evidence = Array(
                        Set(value.evidence + ["HealthKit 수면 기록"])
                    ).sorted()
                    value.modelVersion = "healthkit-sleep-v1"
                    return value
                }
            let existingHealthActuals = snapshot.actuals.filter {
                ($0.source == .healthKit || $0.source == .appleWatch)
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            let stableHealthActuals = ActivityClassificationLockEngine
                .mergingLockedClassifications(
                    existing: existingHealthActuals,
                    fresh: visibleFreshActuals,
                    inside: span
                )
            let existingSleepSessions = sleepSessions.filter {
                $0.span.intersection(with: span) != nil
            }
            if Set(existingHealthActuals) != Set(visibleFreshActuals) {
                await archiveRawDeviceData(
                    source: .healthKit,
                    kind: "health-actuals",
                    payload: freshActuals,
                    capturedAt: span.end
                )
            }
            if Set(existingSleepSessions) != Set(freshSessions) {
                await archiveRawDeviceData(
                    source: .healthKit,
                    kind: "sleep-sessions",
                    payload: freshSessions,
                    capturedAt: span.end
                )
            }
            // HealthKit can legally return an empty result while its daemon,
            // Watch delivery, or authorization is catching up. An empty
            // refresh is not evidence that previously saved records vanished.
            if !visibleFreshActuals.isEmpty {
                snapshot.actuals = AppleDeviceGroundTruthEngine
                    .replacingHealthKitActuals(
                        existing: snapshot.actuals,
                        with: stableHealthActuals,
                        inside: span
                    )
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no actuals; preserving existing records"
                )
            }
            if !freshSessions.isEmpty {
                sleepSessions.removeAll {
                    $0.span.intersection(with: span) != nil
                }
                sleepSessions.append(contentsOf: freshSessions)
                sleepSessions.sort { $0.span.start < $1.span.start }
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no sleep sessions; preserving existing records"
                )
            }
            let coveredAutomaticIDs = SleepActualReconciliationEngine
                .coveredAutomaticIDs(
                    in: snapshot.actuals,
                    by: sleepSessions,
                    inside: span,
                    asOf: min(span.end, .now)
                )
            let reconciledActuals = SleepActualReconciliationEngine.applying(
                snapshot.actuals,
                sessions: sleepSessions,
                inside: span,
                asOf: min(span.end, .now)
            )
            if reconciledActuals != snapshot.actuals {
                snapshot.actuals = reconciledActuals
            }
            // A previous manual correction can otherwise be reapplied by the
            // next persistence pass and turn the authoritative sleep window
            // back into an activity. Keep its time edit only when the record
            // was not covered by HealthKit sleep.
            for id in coveredAutomaticIDs {
                snapshot.settings.activityCorrections.removeValue(forKey: id)
            }
            lastHealthRefreshAt = .now
            Self.integrationLogger.notice(
                "HealthKit refresh completed: actuals=\(freshActuals.count, privacy: .public), sleepSessions=\(freshSessions.count, privacy: .public), periodic=\(requestedSpan != nil, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_refresh_completed",
                fields: healthFields.merging([
                    "actuals": String(freshActuals.count),
                    "sleep_sessions": String(freshSessions.count),
                ]) { _, new in new }
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)",
                    english: "Could not read Health data. \(error.localizedDescription)"
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_refresh_failed",
                level: .error,
                fields: healthFields.merging(
                    TaptionDiagnosticError.fields(for: error)
                ) { _, new in new }
            )
        }
    }

    private func refreshAppUsageData(
        in span: TimeSpan,
        showErrors: Bool = false
    ) async {
        refreshAppUsageAuthorizationState()
        guard appUsageAuthorizationState == .approved,
              !isAppUsageRefreshRunning else {
            return
        }
        isAppUsageRefreshRunning = true
        defer { isAppUsageRefreshRunning = false }

        do {
            let samples = try await screenTimeUsageService.usage(in: span)
            let fresh = ScreenTimeUsageRecordEngine.records(
                from: samples,
                suppressedIDs: snapshot.settings.suppressedActualIDs
            )
            if !samples.isEmpty {
                let updated = ScreenTimeUsageRecordEngine.replacing(
                    existing: snapshot.actuals,
                    with: fresh,
                    inside: span
                )
                if snapshot.actuals != updated {
                    snapshot.actuals = updated
                }
            } else {
                Self.integrationLogger.notice(
                    "Screen Time returned no samples; preserving existing records"
                )
            }
            appUsageRecordCount = fresh.count
            appUsageTotalDuration = fresh.reduce(into: 0) {
                $0 += $1.span(asOf: span.end).duration
            }
            appUsageTokenIndex = ScreenTimeUsageRecordEngine
                .applicationTokenIndex(from: samples)
            lastAppUsageRefreshAt = .now
            Self.integrationLogger.notice(
                "Screen Time refresh completed: samples=\(samples.count, privacy: .public), records=\(fresh.count, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_time_refresh_completed",
                fields: [
                    "samples": String(samples.count),
                    "records": String(fresh.count),
                ]
            )
        } catch {
            Self.integrationLogger.error(
                "Screen Time refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if let screenTimeError = error as? ScreenTimeUsageError {
                switch screenTimeError {
                case .dataAccessUnavailable, .dataAccessNotGranted:
                    appUsageAuthorizationState = .dataAccessUnavailable
                    snapshot.settings.permissions[.appUsage] = .unavailable
                default:
                    break
                }
            }
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "앱 사용시간을 읽지 못했습니다. \(error.localizedDescription)",
                    english: "Could not read app usage time. \(error.localizedDescription)"
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_time_refresh_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
        }
    }

    private func handleObservedHealthChange() async {
        guard acceptsDataMutation() else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        receiveSensorWake(.healthKitBackgroundDelivery)
        await bootstrap()
        guard acceptsDataMutation(), settings.healthEnabled else { return }
        await refreshHealthData(
            in: periodicHealthSpan,
            showErrors: false
        )
        logAutomaticRecordSummary()
        await persistDeviceLocalSnapshot()
    }

    private func startForegroundHealthRefreshIfNeeded() {
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        guard isSceneActive, settings.healthEnabled else { return }

        foregroundHealthRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            HealthRefreshPolicy.foregroundInterval
                        )
                    )
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      self.isSceneActive,
                      self.settings.healthEnabled else {
                    return
                }
                await self.refreshHealthData(
                    in: self.periodicHealthSpan,
                    showErrors: false
                )
                self.logAutomaticRecordSummary()
                await self.persistDeviceLocalSnapshot()
            }
        }
    }

    private func configureHealthBackgroundDeliveryIfNeeded(
        showErrors: Bool
    ) async {
        guard settings.healthEnabled,
              !isHealthBackgroundDeliveryConfigured else {
            return
        }
        do {
            try await healthService.enableBackgroundDelivery()
            isHealthBackgroundDeliveryConfigured = true
            Self.integrationLogger.notice(
                "HealthKit background delivery enabled for available sample types"
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit background delivery failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 데이터 자동 갱신을 켜지 못했습니다. ",
                    english: "Could not turn on automatic Health data refresh. "
                ) + error.localizedDescription
            }
        }
    }

    private func logAutomaticRecordSummary() {
        let today = TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
        let calendarCount = snapshot.calendarEvents.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let placeCount = snapshot.places.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let travelCount = snapshot.travel.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let activityCount = AutomaticRecordTimelineEngine.activities(
            from: snapshot.actuals,
            inside: today
        ).count
        Self.integrationLogger.notice(
            "Today automatic records: schedules=\(calendarCount, privacy: .public), locations=\(placeCount, privacy: .public), movements=\(travelCount, privacy: .public), activities=\(activityCount, privacy: .public)"
        )
    }

    private func resumeSensorCollectionIfNeeded() {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            updateForegroundLiveLocationTracking()
            isSensorCollecting = false
            sensorBackgroundCoordinator.cancel()
            syncSensorBackgroundState()
            return
        }
        let allowsBackgroundLocation =
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization:
                    sensorService.hasAlwaysLocationAuthorization()
            )
        snapshot.settings.backgroundPreciseLocationEnabled =
            allowsBackgroundLocation
        sensorService.startCollection(configuration: sensorCollectionConfiguration(
            profile: settings.sensorCollectionProfile,
            allowsBackgroundLocation: allowsBackgroundLocation
        ))
        updateForegroundLiveLocationTracking()
        isSensorCollecting = true
        if sensorBackgroundCoordinator.lastWakeReason == nil {
            receiveSensorWake(.foregroundResume)
        } else {
            syncSensorBackgroundState()
        }
        reconcileBackgroundSensorSession()
    }

    private func updateForegroundLiveLocationTracking() {
        let enabled = ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: isSceneActive,
            locationCollectionEnabled: settings.locationEnabled,
            hasLocationPermission:
                permissionState(for: .location).isGranted
        )
        sensorService?.setForegroundLiveLocationTrackingEnabled(enabled)
    }

    private var hasContinuousBackgroundCollection: Bool {
        isSensorCollecting
            && sensorService?.isCollectionLive() == true
            && settings.backgroundPreciseLocationEnabled
            && sensorService?.hasAlwaysLocationAuthorization() == true
    }

    private func reconcileBackgroundSensorSession(at date: Date = .now) {
        SensorBackgroundRefreshPolicy.save(
            intervalSeconds: settings.gpsLoggingPreferences
                .effectiveIntervalSeconds
        )
        guard hasContinuousBackgroundCollection else {
            if activeTrackingSession == nil {
                sensorBackgroundCoordinator.endSession()
                syncSensorBackgroundState()
            }
            return
        }
        _ = sensorBackgroundCoordinator.beginCollectionSession(at: date)
        syncSensorBackgroundState()
    }

    private func resumeSensorCollectionAndRestoreTrackingIfNeeded() async {
        guard acceptsDataMutation() else {
            await sensorService?.stopCollectionAndWait()
            isSensorCollecting = false
            return
        }
        resumeSensorCollectionIfNeeded()
        await restoreTrackingSessionIfNeeded()
    }

    private func restoreTrackingSessionIfNeeded() async {
        let generation = dataDeletionGeneration
        guard activeTrackingSession == nil,
              acceptsDataMutation(),
              settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService,
              var session = TrackingSessionRecoveryStore.read() else {
            return
        }

        let now = Date.now
        // A running/walking session left open for more than a day is almost
        // certainly a stale crash record rather than a real workout.
        guard session.endedAt == nil,
              now.timeIntervalSince(session.startedAt) <= 24 * 60 * 60 else {
            TrackingSessionRecoveryStore.clear()
            return
        }
        guard !Task.isCancelled,
              generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: session.startedAt) else {
            return
        }

        session.endedAt = nil
        guard generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: session.startedAt),
              !Task.isCancelled else { return }
        let restored = sensorService.resumeTracking(
            session,
            preferences: settings.gpsLoggingPreferences
        )
        activeTrackingSession = restored
        trackingSessionWasRecovered = true
        lastTrackingSessionRecoveryPersistAt = now
        let readings = (try? await sensorService.archivedRouteReadings(
            for: restored,
            through: now
        )) ?? []
        guard generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: restored.startedAt),
              !Task.isCancelled else {
            await sensorService.stopCollectionAndWait()
            activeTrackingSession = nil
            trackingSessionWasRecovered = false
            isSensorCollecting = false
            return
        }
        let routeReadings = readings
            .filter(TrackingSessionPolicy.isPreciseRouteReading)
            .suffix(4_000)
        liveRouteState = LiveRouteState(
            session: restored,
            readings: Array(routeReadings),
            lastUpdatedAt: readings.last?.timestamp ?? restored.startedAt
        )
        TrackingSessionRecoveryStore.save(restored)
        if restored.wasAutomaticallyDetected,
           settings.gpsLoggingPreferences.effectiveIntervalSeconds
                == GPSLoggingPreferences.Preset.realtime.intervalSeconds {
            _ = sensorBackgroundCoordinator.beginAutomaticSession(at: now)
            syncSensorBackgroundState()
        }
        Self.integrationLogger.notice(
            "Recovered tracking session \(restored.id.uuidString, privacy: .public) with \(readings.count, privacy: .public) archived samples"
        )
    }

    private func updateFloorEstimate(
        with reading: SensorReading
    ) {
        latestSensorReading = reading
        scheduleWeatherDayFixIfNeeded()
        guard let point = reading.point,
              let match = settings.frequentPlaces
                .compactMap({ place -> (FrequentPlace, Double)? in
                    guard place.isAutomaticRecordingEnabled,
                          let reference = place.point,
                          place.floorCalibration != nil else {
                        return nil
                    }
                    let distance = distanceMeters(point, reference)
                    return distance <= place.radiusMeters
                        ? (place, distance)
                        : nil
                })
                .min(by: { $0.1 < $1.1 })?.0,
              let calibration = match.floorCalibration else {
            latestAltitudeEstimate = nil
            return
        }
        guard let estimate = FloorCalibrationEngine().estimate(
            reading: reading,
            calibration: calibration
        ) else {
            latestAltitudeEstimate = nil
            return
        }
        if altitudeGatePlaceID != match.id {
            altitudeGatePlaceID = match.id
            altitudeSpikeGate.reset()
        }
        // 튀는 고도 표본은 이상치로 스킵하고 직전 추정을 유지한다.
        guard altitudeSpikeGate.accept(estimate.seaLevelAltitudeMeters) else {
            return
        }
        latestAltitudeEstimate = estimate
        let knownFloors = calibration.knownFloors
        guard !knownFloors.contains(estimate.floor),
              abs(estimate.floor - calibration.referenceFloor) >= 1,
              estimate.confidence != .low else {
            return
        }
        let key = "\(match.id.uuidString):\(estimate.floor)"
        guard lastAutoFloorCalibrationKey != key else { return }
        lastAutoFloorCalibrationKey = key
        // 보정은 사용자 확인 없이 감지된 위치의 장소에 바로 적용하고
        // 결과만 알린다. 이미 알고 있는 층이면 위 guard에서 끝난다.
        if recordFloorCalibration(
            placeID: match.id,
            floor: estimate.floor,
            reading: reading,
            seaLevelAltitudeMeters: estimate.seaLevelAltitudeMeters
        ) {
            showFloorCalibrationNotice(
                AppLanguagePreference.text(
                    korean: "\(match.name) \(FloorLabel.korean(estimate.floor)) 고도 보정을 적용했습니다.",
                    english: "Applied altitude calibration for \(match.name) \(FloorLabel.english(estimate.floor))."
                )
            )
        }
    }

    private func handlePersistedSensorReadings(
        _ readings: [SensorReading]
    ) {
        let validReadings = readings.filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
        }
        guard let latest = validReadings.max(by: {
            $0.timestamp < $1.timestamp
        }) else { return }
        if let sensorService {
            _ = sensorBackgroundCoordinator.markSaved(
                at: latest.timestamp,
                persistedToken: sensorService.persistenceToken()
            )
            if !settings.backgroundPreciseLocationEnabled {
                _ = sensorBackgroundCoordinator.expireIfNeeded(
                    at: latest.timestamp
                )
            }
            syncSensorBackgroundState()
        }
        for reading in validReadings.sorted(by: {
            $0.timestamp < $1.timestamp
        }) {
            handleLiveSensorReading(reading)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.reconcileSensorCollectionLiveActivity(
                isForeground: self.isSceneActive
            )
        }
    }

    /// 앱이 열려 있을 때 저장·일자 로딩을 기다리지 않고 현재 위치와 경로를 바로 반영한다.
    private func applyLiveReadingPreview(_ reading: SensorReading) {
        guard isSceneActive, let point = reading.point,
              RouteTimelineTimestamp.isValid(reading.timestamp) else { return }
        if let latest = latestSensorReading, latest.timestamp > reading.timestamp {
            return
        }
        if latestSensorReading?.id != reading.id {
            latestSensorReading = reading
        }
        guard TrackingSessionPolicy.isPreciseRouteReading(reading),
              !liveRouteState.readings.suffix(3).contains(where: { $0.id == reading.id })
        else { return }
        let moved = liveRouteState.readings.last?.point.map {
            distanceMeters($0, point) >= 2
        } ?? true
        guard moved else { return }
        liveRouteState.readings.append(reading)
        if liveRouteState.readings.count > Self.liveRouteSoftLimit {
            liveRouteState.readings.removeFirst(
                liveRouteState.readings.count - Self.liveRouteHardLimit
            )
        }
        liveRouteState.lastUpdatedAt = reading.timestamp
    }

    private func handleLiveSensorReading(_ reading: SensorReading) {
        if reading.locationFixQuality == .approximate {
            latestSensorReading = reading
        } else {
            updateFloorEstimate(with: reading)
        }
        let session: TrackingSession?
        if let sessionID = reading.trackingSessionID,
           let kind = reading.trackingKind {
            if activeTrackingSession?.id == sessionID {
                session = activeTrackingSession
            } else {
                session = TrackingSession(
                    id: sessionID,
                    kind: kind,
                    startedAt: reading.timestamp,
                    linkedPlanID: nil,
                    sourceDevice: reading.sourceDevice ?? .iPhone,
                    wasAutomaticallyDetected:
                        reading.trackingWasAutomaticallyDetected
                        ?? (kind == .automatic
                            && reading.sourceDevice == .iPhone)
                )
                activeTrackingSession = session
            }
            if liveRouteState.session?.id != sessionID {
                liveRouteState.readings = []
            }
        } else {
            session = activeTrackingSession
        }

        if reading.trackingSessionEnded == true {
            sensorBackgroundCoordinator.finishTrackingSession(
                continuesCollection: hasContinuousBackgroundCollection,
                at: reading.timestamp
            )
        } else if session?.wasAutomaticallyDetected == true,
                  settings.gpsLoggingPreferences.effectiveIntervalSeconds
                    == GPSLoggingPreferences.Preset.realtime.intervalSeconds {
            _ = sensorBackgroundCoordinator.beginAutomaticSession(
                at: reading.timestamp
            )
        }
        syncSensorBackgroundState()

        reconcileBackgroundSensorSession(at: reading.timestamp)

        if let session {
            let shouldPersistSession = reading.trackingSessionEnded == true
                || lastTrackingSessionRecoveryPersistAt.map {
                    reading.timestamp.timeIntervalSince($0) >= 30
                } ?? true
            if shouldPersistSession {
                if reading.trackingSessionEnded == true {
                    TrackingSessionRecoveryStore.clear()
                    lastTrackingSessionRecoveryPersistAt = nil
                } else {
                    TrackingSessionRecoveryStore.save(session)
                    lastTrackingSessionRecoveryPersistAt = reading.timestamp
                }
            }
        }

        if let point = reading.point {
            if TrackingSessionPolicy.isPreciseRouteReading(reading),
               !liveRouteState.readings.suffix(3).contains(where: { $0.id == reading.id }) {
                let lastPoint = liveRouteState.readings.last?.point
                let shouldAppend = lastPoint.map {
                    distanceMeters($0, point) >= 2
                } ?? true
                if shouldAppend {
                    liveRouteState.readings.append(reading)
                    if liveRouteState.readings.count > Self.liveRouteSoftLimit {
                        liveRouteState.readings.removeFirst(
                            liveRouteState.readings.count - Self.liveRouteHardLimit
                        )
                    }
                }
            }
            if reading.locationFixQuality != .approximate {
                refreshCurrentEnvironmentIfNeeded(
                    point: point,
                    at: reading.timestamp
                )
            }
        }
        liveRouteState.session = session
        liveRouteState.lastUpdatedAt = reading.timestamp

        if reading.trackingSessionEnded == true,
           var completed = session {
            completed.endedAt = reading.timestamp
            if reading.sourceDevice != .appleWatch {
                finalizeTrackingSession(completed)
            }
            activeTrackingSession = nil
            trackingSessionWasRecovered = false
            liveRouteState.session = nil
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: true
            )
        } else {
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: false
            )
        }
    }

    private func scheduleSensorAnalysis(
        containing date: Date,
        immediately: Bool
    ) {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        sensorAnalysisRequestRevision &+= 1
        pendingSensorAnalysisRevisions[day] = sensorAnalysisRequestRevision
        startSensorAnalysis(immediately: immediately)
    }

    private func startSensorAnalysis(immediately: Bool) {
        guard isSceneActive else { return }
        if !immediately, sensorAnalysisDebounceTask != nil { return }
        if immediately { sensorAnalysisDebounceTask?.cancel() }
        sensorAnalysisTaskGeneration &+= 1
        let generation = sensorAnalysisTaskGeneration
        let debounceDelay = sensorAnalysisDebounceDelay
        sensorAnalysisDebounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: debounceDelay)
            }
            guard !Task.isCancelled,
                  let self,
                  self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            let batch = self.pendingSensorAnalysisRevisions.sorted {
                $0.key < $1.key
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_analysis_batch_started",
                fields: [
                    "days": String(batch.count),
                    "immediate": String(immediately),
                ]
            )
            var failedDays = 0
            for (day, revision) in batch {
                guard !Task.isCancelled,
                      self.sensorAnalysisTaskGeneration == generation else {
                    return
                }
                let succeeded = await self.refreshSensorTimeline(
                    containing: day
                )
                if succeeded,
                   self.pendingSensorAnalysisRevisions[day] == revision {
                    self.pendingSensorAnalysisRevisions[day] = nil
                } else if !succeeded {
                    failedDays += 1
                }
            }
            guard !Task.isCancelled,
                  self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            await self.persistDeviceLocalSnapshot()
            guard self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            self.sensorAnalysisDebounceTask = nil
            if failedDays > 0 {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_analysis_retry_scheduled",
                    level: .notice,
                    fields: ["days": String(failedDays)]
                )
            }
            if !self.pendingSensorAnalysisRevisions.isEmpty {
                self.startSensorAnalysis(immediately: false)
            }
        }
    }

    private func cancelSensorAnalysisUntilForeground() {
        sensorAnalysisTaskGeneration &+= 1
        sensorAnalysisDebounceTask?.cancel()
        sensorAnalysisDebounceTask = nil
    }

    private func weatherPreviewRange(from date: Date) -> TimeSpan {
        let start = WeatherTimelineEngine.hourBucket(for: date)
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.date(
            byAdding: .day,
            value: Self.weatherPreviewMaximumDays,
            to: start
        ) ?? start.addingTimeInterval(
            TimeInterval(Self.weatherPreviewMaximumDays) * 24 * 60 * 60
        )
        return TimeSpan(start: start, end: end)
    }

    /// 자정이 지나면 전날 날씨를 그날의 GPS 위치 기준으로 고정해 저장한다(WTH1020C01). 새 위치 점이 들어올 때와 앞으로 올 때
    /// 확인하고(iOS가 앱 실행을 허용한 때에만 동작), 아직 고정하지 않은 지난 날(최대 3일)을 오래된 날부터 처리한다.
    /// 실패하면 30분 뒤에 다시 시도하고, 받은 시간이 하나도 없는 날은 고정한 것으로 치지 않는다.
    private func scheduleWeatherDayFixIfNeeded(now: Date = .now) {
        guard weatherFixTask == nil,
              settings.locationEnabled || settings.weatherEnabled,
              lastWeatherFixAttemptAt.map({ now.timeIntervalSince($0) >= Self.weatherFixRetryInterval }) ?? true
        else { return }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let fixedThrough = UserDefaults.standard.object(forKey: Self.weatherFixedThroughDayKey) as? Double
        let earliest = calendar.date(byAdding: .day, value: -Self.weatherFixBackfillDays, to: today) ?? today
        let first = max(earliest, fixedThrough.map {
            calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: $0)) ?? today
        } ?? earliest)
        guard first < today else { return }
        lastWeatherFixAttemptAt = now
        weatherFixTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.weatherFixTask = nil }
            var day = first
            while day < today, !Task.isCancelled {
                guard await self.fixPastDayWeather(day, now: now) else { break }
                UserDefaults.standard.set(day.timeIntervalSince1970, forKey: Self.weatherFixedThroughDayKey)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? today
            }
        }
    }

    /// 한 날을 고정한다. 하나 이상의 시간을 받아 저장하면 true.
    private func fixPastDayWeather(_ dayStart: Date, now: Date) async -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        let readings = await sensorReadings(in: TimeSpan(start: dayStart, end: dayEnd))
        let home = settings.frequentPlaces.first { $0.kind == .home }?.point
        let hours = WeatherDayFixEngine.hourLocations(
            dayStart: dayStart, dayEnd: dayEnd, readings: readings, home: home, calendar: calendar
        )
        guard !hours.isEmpty else { return false }
        var fixed: [WeatherContext] = []
        for group in WeatherDayFixEngine.groups(hours) {
            do {
                let contexts = try await weatherService.historicalHourlyContexts(
                    latitude: group.point.latitude,
                    longitude: group.point.longitude,
                    from: group.start,
                    through: group.end
                )
                for var context in contexts {
                    context.isForecast = false
                    context.point = group.point
                    context.placeName = "GPS"
                    fixed.append(context)
                }
            } catch is CancellationError {
                return false
            } catch {
                recordWeatherFailure(WeatherFailureKind.kind(for: error), at: now)
                if (error as? WeatherContextServiceError) == .authenticationFailed { break }
            }
        }
        guard !fixed.isEmpty, acceptsDataMutation() else { return false }
        await archiveWeatherRawContexts(fixed, kind: "weather-fixed-hourly")
        snapshot.weather = WeatherDayFixEngine.replacing(snapshot.weather, withFixed: fixed, calendar: calendar)
        TaptionPlanDiagnosticsLogger.shared.record(
            "weather_day_fixed",
            fields: [
                "day": String(dayStart.timeIntervalSince1970),
                "hours": String(fixed.count),
                "locations": String(WeatherDayFixEngine.groups(hours).count),
            ]
        )
        _ = await persistDeviceLocalSnapshot()
        return true
    }

    private func refreshFutureWeatherPreviewIfNeeded() async {
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled,
              liveWeatherRefreshTask == nil else {
            return
        }
        let point = latestSensorReading?.point
            ?? snapshot.weather
                .max { $0.observedAt < $1.observedAt }?.point
        guard let point else { return }

        await refreshFutureWeatherIfNeeded(at: point)
    }

    private func refreshFutureWeatherIfNeeded(
        at point: GeoPoint,
        now: Date = .now
    ) async {
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled,
              liveWeatherRefreshTask == nil else {
            return
        }

        let movedToNewLocation = lastFutureWeatherPoint.map {
            distanceMeters($0, point) >= 1_000
        } ?? true
        let refreshDue = lastFutureWeatherRefreshAt.map {
            now.timeIntervalSince($0) >= Self.weatherPreviewRefreshInterval
        } ?? true
        guard movedToNewLocation || refreshDue else { return }

        let range = weatherPreviewRange(from: now)
        do {
            let fetched = try await weatherService.hourlyContexts(
                latitude: point.latitude,
                longitude: point.longitude,
                from: range.start,
                through: range.end
            )
            let futureStart = max(now, range.start)
            var contexts = fetched.filter {
                $0.observedAt >= futureStart && $0.observedAt < range.end
            }
            guard isSceneActive,
                  acceptsDataMutation(),
                  !Task.isCancelled else { return }
            guard !contexts.isEmpty else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "weather_preview_empty",
                    level: .notice,
                    fields: [
                        "from": String(range.start.timeIntervalSince1970),
                        "through": String(range.end.timeIntervalSince1970),
                    ]
                )
                return
            }
            lastFutureWeatherRefreshAt = now
            lastFutureWeatherPoint = point
            for index in contexts.indices {
                contexts[index].isForecast = true
                contexts[index].point = point
                contexts[index].placeName = "현재 위치"
            }
            await archiveWeatherRawContexts(
                contexts,
                kind: "weather-forecast-hourly"
            )
            snapshot.weather = WeatherTimelineEngine.replacing(
                snapshot.weather,
                forecast: contexts,
                forecastRange: range
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_preview_refreshed",
                fields: [
                    "contexts": String(contexts.count),
                    "from": String(range.start.timeIntervalSince1970),
                    "through": String(range.end.timeIntervalSince1970),
                ]
            )
            await persistDeviceLocalSnapshot()
        } catch is CancellationError {
            return
        } catch {
            recordWeatherFailure(WeatherFailureKind.kind(for: error), at: now)
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_preview_failed",
                level: .error,
                fields: [
                    "error": String(describing: type(of: error)),
                    "from": String(range.start.timeIntervalSince1970),
                    "through": String(range.end.timeIntervalSince1970),
                ]
            )
        }
    }

    private func refreshCurrentEnvironmentIfNeeded(
        point: GeoPoint,
        at date: Date
    ) {
        // Weather is part of the automatic sensor record. Location collection
        // enables it even when the legacy weather toggle is still off.
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled else {
            return
        }
        let movedFarEnough = lastLiveEnvironmentPoint.map {
            distanceMeters($0, point) >= 3_000
        } ?? true
        // Keep environment samples on the same cadence as the configured
        // GPS/sensor duty cycle.  The provider caches the value, so a one-
        // minute accuracy profile does not imply a one-minute network call.
        let collectionInterval = settings.sensorCollectionProfile.interval
        let agedEnough = lastLiveEnvironmentAt.map {
            date.timeIntervalSince($0) >= collectionInterval
        } ?? true
        let retryAllowed = lastLiveEnvironmentFailureAt.map {
            date.timeIntervalSince($0) >= 60
        } ?? true
        let now = Date.now
        let futureRefreshDue = lastFutureWeatherRefreshAt.map {
            now.timeIntervalSince($0) >= Self.weatherPreviewRefreshInterval
        } ?? true
        let futureMovedToNewLocation = lastFutureWeatherPoint.map {
            distanceMeters($0, point) >= 1_000
        } ?? true
        let shouldRefreshFutureWeather =
            futureMovedToNewLocation || futureRefreshDue
        guard movedFarEnough || agedEnough,
              retryAllowed,
              liveWeatherRefreshTask == nil else { return }
        liveWeatherRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.liveWeatherRefreshTask = nil }
            do {
                var context = try await self.weatherService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                context.point = point
                context.placeName = "현재 위치"
                context.airQuality = try? await self.airQualityService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }

                var futureContexts: [WeatherContext] = []
                var futureRange: TimeSpan?
                if shouldRefreshFutureWeather {
                    let range = self.weatherPreviewRange(from: now)
                    let futureStart = max(now, range.start)
                    do {
                        let fetched = try await self.weatherService
                            .hourlyContexts(
                                latitude: point.latitude,
                                longitude: point.longitude,
                                from: range.start,
                                through: range.end
                            )
                        futureContexts = fetched.filter {
                            $0.observedAt >= futureStart
                                && $0.observedAt < range.end
                            }
                        if !futureContexts.isEmpty {
                            futureRange = range
                            self.lastFutureWeatherRefreshAt = now
                            self.lastFutureWeatherPoint = point
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.recordWeatherFailure(
                            WeatherFailureKind.kind(for: error),
                            at: now
                        )
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "weather_preview_failed",
                            level: .error,
                            fields: [
                                "error": String(describing: type(of: error)),
                                "from": String(range.start.timeIntervalSince1970),
                                "through": String(range.end.timeIntervalSince1970),
                            ]
                        )
                    }
                }

                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }
                for index in futureContexts.indices {
                    futureContexts[index].isForecast = true
                    futureContexts[index].point = point
                    futureContexts[index].placeName = "현재 위치"
                }
                await self.archiveWeatherRawContexts(
                    [context],
                    kind: "weather-context"
                )
                await self.archiveWeatherRawContexts(
                    futureContexts,
                    kind: "weather-forecast-hourly"
                )
                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }
                self.lastLiveEnvironmentPoint = point
                self.lastLiveEnvironmentAt = date
                self.lastLiveEnvironmentFailureAt = nil
                self.recordWeatherSuccess(context)
                self.snapshot.weather = WeatherTimelineEngine.replacing(
                    self.snapshot.weather,
                    current: context,
                    forecast: futureContexts,
                    forecastRange: futureRange
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_refreshed",
                    fields: [
                        "air_quality": String(context.airQuality != nil),
                        "forecast_contexts": String(futureContexts.count),
                    ]
                )
                await self.persistDeviceLocalSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self.lastLiveEnvironmentFailureAt = date
                Self.integrationLogger.info(
                    "Live weather context unavailable: \(error.localizedDescription, privacy: .public)"
                )
                let failureKind = WeatherFailureKind.kind(for: error)
                self.recordWeatherFailure(failureKind, at: date)
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_failed",
                    level: .error,
                    fields: [
                        "error": String(describing: type(of: error)),
                        "authentication": String(failureKind == .authentication),
                    ]
                )
            }
        }
    }

    private func finalizeTrackingSession(_ session: TrackingSession) {
        guard finalizedTrackingSessionIDs.insert(session.id).inserted else {
            return
        }
        let end = max(session.startedAt, session.endedAt ?? .now)
        let kind = session.kind == .running ? "달리기" : "걷기"
        let linkedPlan = session.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        snapshot.actuals.append(
            ActualRecord(
                id: session.id,
                planID: linkedPlan?.id,
                title: linkedPlan?.title ?? kind,
                categoryID: linkedPlan?.categoryID ?? "activity",
                startedAt: session.startedAt,
                endedAt: end,
                source: session.sourceDevice == .appleWatch
                    ? .appleWatch
                    : .location,
                confidence: .high
            )
        )
    }

    private nonisolated static func migrateLegacyFloorCalibration(
        in snapshot: inout TaptionDataSnapshot
    ) {
        guard let calibration = snapshot.settings.floorCalibration else {
            return
        }
        defer { snapshot.settings.floorCalibration = nil }
        guard calibration.isCaptured,
              let point = calibration.referencePoint,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.kind == .home
              }) else {
            return
        }
        let existingPoint =
            snapshot.settings.frequentPlaces[index].point
        if let existingPoint,
           distanceMeters(existingPoint, point)
            > snapshot.settings.frequentPlaces[index].radiusMeters {
            return
        }
        if existingPoint == nil {
            snapshot.settings.frequentPlaces[index].point = point
        }
        if snapshot.settings.frequentPlaces[index].floor == nil {
            snapshot.settings.frequentPlaces[index].floor =
                calibration.referenceFloor
        }
        snapshot.settings.frequentPlaces[index]
            .referenceRelativeAltitudeMeters =
                snapshot.settings.frequentPlaces[index]
                    .referenceRelativeAltitudeMeters
                ?? calibration.referenceRelativeAltitudeMeters
        snapshot.settings.frequentPlaces[index]
            .referencePressureKilopascals =
                snapshot.settings.frequentPlaces[index]
                    .referencePressureKilopascals
                ?? calibration.referencePressureKilopascals
        snapshot.settings.frequentPlaces[index]
            .referenceAltimeterSessionID =
                snapshot.settings.frequentPlaces[index]
                    .referenceAltimeterSessionID
                ?? calibration.referenceAltimeterSessionID
        snapshot.settings.frequentPlaces[index].floorCapturedAt =
            snapshot.settings.frequentPlaces[index].floorCapturedAt
            ?? calibration.capturedAt
        snapshot.settings.frequentPlaces[index].updatedAt =
            calibration.capturedAt ?? .now
    }

    private func weatherNeedsRefresh(for reading: SensorReading?) -> Bool {
        guard let reading, let point = reading.point else { return false }
        let latest = snapshot.weather
            .filter { context in
                guard let contextPoint = context.point,
                      context.placeID == nil,
                      context.observedAt <= reading.timestamp else {
                    return false
                }
                return distanceMeters(contextPoint, point) < 1_000
            }
            .max { $0.observedAt < $1.observedAt }
        guard let latest else { return true }
        return reading.timestamp.timeIntervalSince(latest.observedAt)
            >= settings.sensorCollectionProfile.interval
    }

    private func refreshWeather(
        in span: TimeSpan,
        fallbackReading: SensorReading? = nil
    ) async {
        let calendar = Calendar.autoupdatingCurrent
        guard calendar.isDate(span.start, inSameDayAs: .now) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_historical_restored",
                fields: [
                    "from": String(span.start.timeIntervalSince1970),
                    "through": String(span.end.timeIntervalSince1970),
                ]
            )
            return
        }
        let latestStoredPoint = snapshot.weather
            .filter { $0.point != nil && $0.isForecast != true }
            .max(by: { $0.observedAt < $1.observedAt })?.point
        guard let point = fallbackReading?.point
            ?? latestSensorReading?.point
            ?? latestStoredPoint else {
            return
        }
        await refreshWeather(at: point, observedAt: .now)
    }

    private func refreshWeather(
        at point: GeoPoint,
        observedAt: Date,
        placeID: UUID? = nil,
        placeName: String? = "현재 위치"
    ) async {
        do {
            var context = try await weatherService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            context.observedAt = observedAt
            context.placeID = placeID
            context.placeName = placeName
            context.point = point
            context.airQuality = try? await airQualityService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            guard !Task.isCancelled, acceptsDataMutation() else { return }
            await archiveWeatherRawContexts(
                [context],
                kind: "weather-context"
            )
            guard !Task.isCancelled, acceptsDataMutation() else { return }
            snapshot.weather = WeatherTimelineEngine.replacing(
                snapshot.weather,
                current: context
            )
            recordWeatherSuccess(context)
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_refreshed",
                fields: [
                    "air_quality": String(context.airQuality != nil),
                ]
            )
            await persistDeviceLocalSnapshot()
            if placeID == nil {
                await refreshFutureWeatherIfNeeded(at: point)
            }
        } catch {
            Self.integrationLogger.info(
                "Stored weather fallback unavailable: \(error.localizedDescription, privacy: .public)"
            )
            let failureKind = WeatherFailureKind.kind(for: error)
            recordWeatherFailure(failureKind, at: .now)
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_failed",
                level: .error,
                fields: [
                    "error": String(describing: type(of: error)),
                    "authentication": String(failureKind == .authentication),
                ]
            )
        }
    }

    private func recordWeatherSuccess(_ context: WeatherContext) {
        // 오래된 값(실패 뒤 캐시)은 성공으로 세지 않는다.
        guard context.isStale != true else { return }
        var next = weatherStatus
        guard next.recordSuccess(at: .now) else { return }
        weatherStatus = next
    }

    private func recordWeatherFailure(_ kind: WeatherFailureKind, at date: Date) {
        var next = weatherStatus
        guard next.recordFailure(kind, at: date) else { return }
        weatherStatus = next
    }

    private func coalesceWeatherSnapshot() {
        snapshot.weather = WeatherTimelineEngine.coalesced(snapshot.weather)
    }

    private func applyPendingWidgetCommands(
        repositoryAlreadyLoaded: Bool
    ) async {
        guard let commands = try? TaptionWidgetSharedStore.takeCommands(),
              !commands.isEmpty else {
            return
        }
        if !repositoryAlreadyLoaded,
           commands.contains(where: {
               $0.appliedToSharedRepository == true
           }),
           let reloaded = try? await repository.load() {
            snapshot = reloaded
        }
        for command in commands {
            guard command.appliedToSharedRepository != true else {
                continue
            }
            do {
                snapshot = try TaptionWidgetCommandEngine.apply(
                    command,
                    to: snapshot
                )
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "위젯 요청을 반영하지 못했습니다. \(error.localizedDescription)",
                    english: "Could not apply the widget request. \(error.localizedDescription)"
                )
            }
        }
    }

    private func normalizedWidgetPayload(
        _ payload: TaptionWidgetPayload
    ) -> TaptionWidgetPayload {
        var normalized = payload
        normalized.generatedAt = .distantPast
        // updatedAt is an envelope timestamp. The source fingerprint and
        // item values carry the actual widget content, so a sensor-only save
        // must not force another app-group write.
        normalized.sourceSnapshotUpdatedAt = nil
        // Recompute-free identity: the fingerprint intentionally includes
        // movement end times, while the comparison below canonicalizes an
        // open movement edge to distantPast.
        normalized.sourceFingerprint = nil
        if let center = payload.displayCenterDate {
            let minute = floor(center.timeIntervalSinceReferenceDate / 60)
            normalized.displayCenterDate = Date(
                timeIntervalSinceReferenceDate: minute * 60
            )
        }
        // Open-ended automatic records use "now" as their presentation end.
        // Ignore that moving edge while comparing payload content.
        normalized.items = payload.items.map { item in
            var item = item
            let isOpenEndedLane =
                item.resolvedLane == .activity
                    || item.resolvedLane == .sleep
                    || item.resolvedLane == .movement
            if isOpenEndedLane,
               item.endsAt >= payload.generatedAt.addingTimeInterval(-120),
               item.endsAt <= payload.generatedAt.addingTimeInterval(120) {
                item.endsAt = .distantPast
            }
            return item
        }
        return normalized
    }

    private func publishWidgetPayload(
        hidesSensitiveContent: Bool? = nil
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let hidesSensitiveContent = hidesSensitiveContent
            ?? TaptionExternalPrivacyStore.isLocked
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now,
            calendar: calendar,
            hidesSensitiveContent: hidesSensitiveContent
        )
        let identity = normalizedWidgetPayload(payload)
        if lastWidgetPayloadIdentity == identity {
            widgetPayloadSkipCount += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastWidgetSkipLogUptime >= 5 {
                lastWidgetSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "widget_payload_skipped",
                    fields: [
                        "reason": "unchanged",
                        "count": String(widgetPayloadSkipCount),
                    ]
                )
            }
            publishWatchPayload(now: now, calendar: calendar)
            return
        }
        do {
            try TaptionWidgetSharedStore.writePayload(payload)
            lastWidgetPayloadIdentity = identity
            let locationCount = payload.items.filter {
                $0.resolvedLane == .location
            }.count
            let movementCount = payload.items.filter {
                $0.resolvedLane == .movement
            }.count
            Self.integrationLogger.notice(
                "Widget ground-truth publish: snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public), generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public), items=\(payload.items.count, privacy: .public), locations=\(locationCount, privacy: .public), movements=\(movementCount, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_published",
                fields: [
                    "items": String(payload.items.count),
                    "locations": String(locationCount),
                    "movements": String(movementCount),
                ]
            )
            requestImmediateWidgetRefresh()
        } catch {
            Self.integrationLogger.error(
                "Widget ground-truth publish failed: \(error.localizedDescription, privacy: .public)"
            )
            userFacingError = AppLanguagePreference.text(
                korean: "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)",
                english: "Could not update widget data. \(error.localizedDescription)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
        publishWatchPayload(now: now, calendar: calendar)
    }

    private func setExternalPrivacyLocked(_ isLocked: Bool) {
        TaptionExternalPrivacyStore.setLocked(isLocked)
        publishWidgetPayload(hidesSensitiveContent: isLocked)
    }

    private func concealExternalSurfaces() async {
        setExternalPrivacyLocked(true)
        await liveActivityController.concealAll()
    }

    /// The iPhone snapshot is the only Watch settings source. This method is
    /// intentionally separate from widget serialization so a settings toggle
    /// reaches the Watch immediately, before disk or iCloud work finishes.
    private func publishWatchPayload(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let hidesSensitiveContent = TaptionExternalPrivacyStore.isLocked
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: dayStart
        )?.start ?? dayStart
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)
        let categoriesByID = Dictionary(
            snapshot.categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeActualsByPlanID = Dictionary(
            snapshot.actuals.compactMap { actual -> (UUID, ActualRecord)? in
                guard let planID = actual.planID,
                      actual.endedAt == nil else { return nil }
                return (planID, actual)
            },
            uniquingKeysWith: { current, candidate in
                current.startedAt >= candidate.startedAt
                    ? current
                    : candidate
            }
        )
        // Watch payloads are a live execution queue, not a copy of the
        // historical timeline.  Keep a currently-running item even when it
        // started before this moment, include upcoming items through the
        // current week, and omit ended/completed/skipped records entirely.
        let watchItems = (hidesSensitiveContent ? [] : snapshot.plans)
            .filter { plan in
                guard plan.span.end > now,
                      plan.span.start < weekEnd else {
                    return false
                }
                return plan.status == .planned || plan.status == .running
            }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = categoriesByID[plan.categoryID]
                let activeActual = activeActualsByPlanID[plan.id]
                return TaptionWatchPlanItem(
                    id: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startsAt: plan.span.start,
                    endsAt: plan.span.end,
                    status: plan.status.rawValue,
                    actualStartedAt: activeActual?.startedAt,
                    categoryName: category?.name,
                    categoryHex: category?.lightHex,
                    isGoal: GoalRecordPolicy.isGoal(plan),
                    parentID: plan.parentID
                )
            }
        let commandCapabilities = hidesSensitiveContent || isCommerceLocked
            ? []
            : TaptionWatchCommandCapabilityStore.reconcile(
                planIDs: Set(watchItems.map(\.id)),
                now: now
            )
        if hidesSensitiveContent || isCommerceLocked {
            TaptionWatchCommandCapabilityStore.clear()
        }
        let watchPayload = TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now,
            viewportEnd: weekEnd,
            items: watchItems,
            catStyle: snapshot.settings.catStyle.rawValue,
            reducesMotion: snapshot.settings.reduceMotion,
            todaySummary: hidesSensitiveContent
                ? nil
                : TaptionWatchDaySummaryFactory.make(
                    plans: snapshot.plans,
                    actuals: snapshot.actuals,
                    at: now,
                    calendar: calendar
                ),
            accelerationSettings: TaptionWatchAccelerationSettings(
                profile: isCommerceLocked
                    ? .off
                    : snapshot.settings.watchAccelerationProfile
            ),
            dataSyncProfile: isCommerceLocked
                ? .off
                : snapshot.settings.watchDataSyncProfile,
            locationTrackingEnabled: isCommerceLocked
                ? false
                : snapshot.settings.locationEnabled,
            locationPermissionState:
                snapshot.settings.permissions[.location]?.rawValue,
            activitySuggestion: hidesSensitiveContent
                ? nil
                : pendingWatchActivitySuggestion.flatMap {
                    now.timeIntervalSince($0.endedAt) <= 2 * 3_600 ? $0 : nil
                },
            commandCapabilities: commandCapabilities,
            commerceLocked: isCommerceLocked,
            languagePreference: AppLanguagePreference.current.watchPayloadValue
        )
        var identity = watchPayload
        identity.generatedAt = .distantPast
        // The live viewport starts at "now" for rendering. It is not payload
        // content, otherwise every sensor callback would queue another Watch
        // transfer even when the execution queue is unchanged.
        identity.viewportStart = dayStart
        if lastWatchPayloadIdentity == identity {
            watchPayloadSkipCount += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastWatchSkipLogUptime >= 5 {
                lastWatchSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_payload_skipped",
                    fields: [
                        "reason": "unchanged",
                        "count": String(watchPayloadSkipCount),
                    ]
                )
            }
            return
        }
        do {
            try watchConnectivityService.update(payload: watchPayload)
            lastWatchPayloadIdentity = identity
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_queued",
                fields: [
                    "acceleration": snapshot.settings
                        .watchAccelerationProfile.displayName,
                    "data_sync": snapshot.settings
                        .watchDataSyncProfile.displayName,
                    "location": String(snapshot.settings.locationEnabled),
                ]
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_publish_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    private func requestImmediateWidgetRefresh() {
        widgetReloadFollowupTask?.cancel()
        Self.integrationLogger.notice("Widget timeline reload requested")
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        WidgetCenter.shared.reloadAllTimelines()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(
                ofKind: TaptionWidgetKind.schedule
            )
            WidgetCenter.shared.reloadAllTimelines()
            Self.integrationLogger.notice("Widget timeline reload follow-up requested")
        }
    }

    private var visibleDataSpan: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let level = selectedScale.timelineLevel
        let aggregation = TimelineAggregationEngine(calendar: calendar)
        let navigation = TimelinePeriodNavigationEngine(calendar: calendar)
        let center = aggregation.interval(for: level, containing: selectedDate)
        let previous = navigation.adjacentDate(
            from: selectedDate,
            level: level,
            direction: -1
        ).map { aggregation.interval(for: level, containing: $0) }
        let next = navigation.adjacentDate(
            from: selectedDate,
            level: level,
            direction: 1
        ).map { aggregation.interval(for: level, containing: $0) }
        return TimeSpan(
            start: previous?.start ?? center.start,
            end: next?.end ?? center.end
        )
    }

    private var currentDeviceDataSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
    }

    private var startupHealthSpan: TimeSpan {
        SleepAnalysisEngine.overnightSpan(containing: .now)
    }

    private var recentHealthSpan: TimeSpan {
        let now = Date.now
        let start = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -31,
            to: Calendar.autoupdatingCurrent.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-31 * 86_400)
        return TimeSpan(start: start, end: now)
    }

    private var periodicHealthSpan: TimeSpan {
        let now = Date.now
        return TimeSpan(
            start: now.addingTimeInterval(
                -HealthRefreshPolicy.periodicLookback
            ),
            end: now
        )
    }

    private var hasCurrentDataGeneration: Bool {
        dataDeletionGeneration
            == TaptionDataDeletionFence.currentGeneration()
    }

    private func allowsRepositoryLoadAttempt() -> Bool {
        !isCommerceLocked
            && !isDeletingUserData
            && TaptionDataDeletionFence.allows(
                generation: dataDeletionGeneration
            )
    }

    private func acceptsDataMutation(capturedAt: Date? = nil) -> Bool {
        !repositoryLoadFailed && !isStartupSnapshotPartial
            && allowsRepositoryLoadAttempt()
            && TaptionDataDeletionFence.allows(
                generation: dataDeletionGeneration,
                capturedAt: capturedAt
            )
    }

    private func assignTimestampOnlySnapshot(_ value: TaptionDataSnapshot) {
        // Persisting a sensor snapshot updates only the envelope timestamp.
        // Mark that assignment so didSet does not compare every historical
        // plan, actual, place and route just to discover that the collections
        // are unchanged.
        timestampOnlySnapshotAssignment = true
        snapshot = value
    }

    private func saveToRepository(
        _ value: TaptionDataSnapshot,
        expectedRevision: UInt64? = nil,
        requiresCurrentRevision: Bool = true,
        actualEdit: PlanActualEdit? = nil
    ) async throws -> Bool {
        guard hasCurrentDataGeneration else {
            throw RepositoryError.staleGeneration
        }
        if let expectedRevision, expectedRevision != snapshotRevision {
            return false
        }
        try Task.checkCancellation()
        let previous = repositoryWriteTask
        let generation = dataDeletionGeneration
        repositoryWriteSequence &+= 1
        let sequence = repositoryWriteSequence
        // A caller disappearing must not discard an accepted local write.
        let task = Task { @MainActor [self] in
            _ = await previous?.result
            guard generation == dataDeletionGeneration,
                  hasCurrentDataGeneration else {
                throw RepositoryError.staleGeneration
            }
            if requiresCurrentRevision,
               let expectedRevision, expectedRevision != snapshotRevision {
                return false
            }
            try await repository.save(value, actualEdit: actualEdit)
            return !requiresCurrentRevision || expectedRevision == nil
                || expectedRevision == snapshotRevision
        }
        repositoryWriteTask = task
        defer {
            if repositoryWriteSequence == sequence { repositoryWriteTask = nil }
        }
        return try await task.value
    }

    @discardableResult
    private func persist(allowingDeletion: Bool = false, actualEdit: PlanActualEdit? = nil) async -> Bool {
        guard hasCurrentDataGeneration,
              allowingDeletion || !isDeletingUserData else { return false }
        if isSensorTimelineRefreshing { userEditedDuringSensorRefresh = true }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Persistence blocked after repository load failure; preserving existing data"
            )
            return false
        }
        do {
            normalizeLocalRecordsIfNeeded()
            var value = snapshotForPersistence()
            value.updatedAt = .now
            var visibleValue = value
            visibleValue.memos = snapshot.memos
            let sourceRevision = snapshotRevision
            guard try await saveToRepository(
                value,
                expectedRevision: sourceRevision,
                requiresCurrentRevision: false,
                actualEdit: actualEdit
            ) else { return false }
            if snapshotRevision == sourceRevision {
                assignTimestampOnlySnapshot(visibleValue)
            }
            schedulePostSaveRefresh()
            publishWidgetPayload()
            await reconcileSensorCollectionLiveActivity(isForeground: isSceneActive)
            if permissionState(for: .notifications).isGranted,
               snapshot.settings.notificationsEnabled {
                do {
                    try await notificationScheduler.synchronize(
                        plans: snapshot.plans
                    )
                } catch {
                    userFacingError = AppLanguagePreference.text(
                        korean: "계획 알림을 갱신하지 못했습니다. \(error.localizedDescription)",
                        english: "Could not update plan notifications. \(error.localizedDescription)"
                    )
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "변경 내용을 저장하지 못했습니다. \(error.localizedDescription)",
                english: "Could not save changes. \(error.localizedDescription)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "local_persistence_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return false
        }
    }

    /// 기기 센서에서만 만들어지는 자동 기록. iCloud로 내보내지 않고 기기
    /// 저장본을 원본으로 유지한다. 새 자동 기록 종류를 더할 때 이 판단을
    /// 두 곳에 나눠 적으면 한쪽이 빠지므로 한 자리에서 본다.
    private nonisolated static func isDeviceLocalActual(
        _ actual: ActualRecord
    ) -> Bool {
        switch actual.source {
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        case .manual, .timer, .calendar, .photo:
            false
        }
    }

    nonisolated static func cloudPortableSnapshot(
        _ source: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(source)
        value.calendarEvents = []
        value.photos = []
        value.memos = value.memos.map { memo in
            var portable = memo
            portable.attachments = []
            return portable
        }
        value.places = value.places.map(LocationPrivacyFilter.timelineSafe)
        value.travel = value.travel.map { segment in
            var safe = segment
            safe.evidence = []
            return safe
        }
        value.settings.floorCalibration = nil
        value.settings.floorCalibrationHistory = []
        value.settings.transitBoardingDecisions = []
        value.settings.predictedRouteDecisions = []
        value.settings.movementCorrections = []
        value.settings.activityCorrections = [:]
        // 거절한 자리는 이 기기의 위치 기록에서만 나온 좌표다. 자주가는 곳
        // 자체와 달리 사용자가 적은 값이 아니므로 기기에 남긴다.
        value.settings.dismissedPlaceSuggestions = []
        return value
    }

    private func mergeDeviceLocalData(
        cloud: TaptionDataSnapshot,
        local: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = cloud
        let cloudSleepSpans = TaptionActivityEngineAdapter
            .migratedConfirmedSleepSpans(
                existing: cloud.settings.confirmedSleepSpans,
                corrections: cloud.settings.activityCorrections,
                actuals: cloud.actuals
            )
        let localSleepSpans = TaptionActivityEngineAdapter
            .migratedConfirmedSleepSpans(
                existing: local.settings.confirmedSleepSpans,
                corrections: local.settings.activityCorrections,
                actuals: local.actuals
            )
        let deviceActuals = local.actuals.filter(Self.isDeviceLocalActual)
        let cloudIDs = Set(value.actuals.map(\.id))
        value.actuals.append(contentsOf: deviceActuals.filter {
            !cloudIDs.contains($0.id)
        })
        value.places = deviceRecords(
            local.places,
            recoveringMissingFrom: value.places,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.travel = deviceRecords(
            local.travel,
            recoveringMissingFrom: value.travel,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.floorTransitions = deviceRecords(
            local.floorTransitions,
            recoveringMissingFrom: value.floorTransitions,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.stickers = deviceRecords(
            local.stickers,
            recoveringMissingFrom: value.stickers,
            id: \.id
        ).sorted { $0.updatedAt < $1.updatedAt }
        value.calendarEvents = local.calendarEvents
        value.photos = local.photos
        value.settings.permissions = local.settings.permissions
        value.settings.showsPhotos = local.settings.showsPhotos
        value.settings.showsPhotosInWidgets =
            local.settings.showsPhotosInWidgets
        value.settings.selectedCalendarIDs =
            local.settings.selectedCalendarIDs
        value.settings.healthEnabled = local.settings.healthEnabled
        value.settings.locationEnabled = local.settings.locationEnabled
        value.settings.backgroundPreciseLocationEnabled =
            local.settings.backgroundPreciseLocationEnabled
        value.settings.sensorCollectionProfile =
            local.settings.sensorCollectionProfile
        value.settings.gpsLoggingPreferences =
            local.settings.gpsLoggingPreferences
        value.settings.mapCategoryColors =
            local.settings.mapCategoryColors
        value.settings.mapUserActivityCategories =
            local.settings.mapUserActivityCategories
        value.settings.mapMemoDisplayFilter =
            local.settings.mapMemoDisplayFilter
        value.settings.watchAccelerationProfile =
            local.settings.watchAccelerationProfile
        value.settings.watchDataSyncProfile =
            local.settings.watchDataSyncProfile
        value.settings.timelineRowOrder =
            AppFeatureSettings.normalizedTimelineRowOrder(
                local.settings.timelineRowOrder
            )
        value.settings.floorCalibration = nil
        value.settings.floorCalibrationHistory =
            local.settings.floorCalibrationHistory
        value.settings.transitBoardingDecisions =
            local.settings.transitBoardingDecisions
        value.settings.predictedRouteDecisions = local.settings.predictedRouteDecisions
        value.settings.movementCorrections =
            local.settings.movementCorrections
        value.settings.activityCorrections =
            local.settings.activityCorrections
        value.settings.confirmedSleepSpans =
            AppFeatureSettings.normalizedConfirmedSleepSpans(
                cloudSleepSpans + localSleepSpans
            )
        value.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: value.settings.confirmedSleepSpans,
                corrections: value.settings.activityCorrections,
                actuals: value.actuals
            )
        value.settings.customActivityLabels =
            AppFeatureSettings.normalizedActivityLabels(
                local.settings.customActivityLabels
            )
        value.settings.dismissedPlaceSuggestions =
            local.settings.dismissedPlaceSuggestions
        // Weather is sampled with device location and remains device ground
        // truth, just like the corresponding place and movement records.
        value.weather = WeatherTimelineEngine.coalesced(local.weather)
        value.settings.suppressedActualIDs.formUnion(
            local.settings.suppressedActualIDs
        )
        value.settings.cloudDeletedRecordKeys.formUnion(
            local.settings.cloudDeletedRecordKeys
        )
        value.settings.cloudResetAt = [
            value.settings.cloudResetAt,
            local.settings.cloudResetAt,
        ].compactMap { $0 }.max()
        value.settings.weatherEnabled = local.settings.weatherEnabled
        value.settings.weatherSidebarVisible = local.settings.weatherSidebarVisible
        value.settings.notificationsEnabled =
            local.settings.notificationsEnabled
        value.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: value.actuals,
            suppressedIDs: value.settings.suppressedActualIDs
        )
        value.actuals = ActivityCorrectionEngine.applying(
            value.settings.activityCorrections,
            to: value.actuals
        )
        value.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            value.settings.confirmedSleepSpans,
            to: value.actuals
        )
        // iCloud can still hand back placeholder plans written by an older
        // build on this or another device.
        MemoShellPlanMigration.apply(to: &value)
        return value
    }

    private func deviceRecords<Element, ID: Hashable>(
        _ local: [Element],
        recoveringMissingFrom cloud: [Element],
        id: KeyPath<Element, ID>
    ) -> [Element] {
        var seen = Set(local.map { $0[keyPath: id] })
        return local + cloud.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private func preparedCloudMergedSnapshot(
        _ value: TaptionDataSnapshot,
        preservingUpdatedAt updatedAt: Date
    ) -> TaptionDataSnapshot {
        var content = value
        content.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: content.settings.confirmedSleepSpans,
                corrections: content.settings.activityCorrections,
                actuals: content.actuals
            )
        content.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            content.settings.confirmedSleepSpans,
            to: content.actuals
        )
        content.updatedAt = updatedAt
        return content
    }

    private func assignCommittedCloudSnapshot(
        _ content: TaptionDataSnapshot
    ) {
        guard content != snapshot else { return }
        snapshot = content
    }

    private func refreshReviewArchives(
        force: Bool,
        asOf: Date = .now
    ) async {
        let interval = max(
            60,
            snapshot.settings.sensorCollectionProfile.interval
        )
        if !force, let lastReviewArchiveRefreshAt,
           lastReviewArchiveRefreshRevision == timelineRevision,
           asOf.timeIntervalSince(lastReviewArchiveRefreshAt) < interval {
            return
        }
        let source = snapshotForPersistence()
        let revision = timelineRevision
        let refreshTask = Task.detached(priority: .utility) {
            try ReviewReportArchiveEngine.refreshed(
                snapshot: source,
                asOf: asOf
            )
        }
        let reports: [YearlyReviewArchive]
        do {
            reports = try await withTaskCancellationHandler {
                try await refreshTask.value
            } onCancel: {
                refreshTask.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "review_archive_refresh_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return
        }
        guard !Task.isCancelled, acceptsDataMutation(),
              revision == timelineRevision else { return }
        lastReviewArchiveRefreshAt = asOf
        lastReviewArchiveRefreshRevision = revision
        guard reports != snapshot.yearlyReports else { return }
        snapshot.yearlyReports = reports
    }

    private func schedulePostSaveRefresh() {
        postSaveRefreshRequested = true
        guard isSceneActive, postSaveRefreshTask == nil else { return }
        postSaveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.postSaveRefreshTask = nil
                if self.postSaveRefreshRequested, self.isSceneActive,
                   self.acceptsDataMutation() {
                    self.schedulePostSaveRefresh()
                }
            }
            while self.postSaveRefreshRequested, self.isSceneActive,
                  self.acceptsDataMutation(), !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                guard self.isSceneActive, !Task.isCancelled else { return }
                self.postSaveRefreshRequested = false
                await self.refreshReviewArchives(force: false)
                guard self.isSceneActive, !Task.isCancelled else { return }
                await self.persistDeviceLocalSnapshot()
                guard self.isSceneActive, !Task.isCancelled else { return }
                await self.synchronizeCloud(showErrors: false)
            }
        }
    }

    private func invalidateReviewArchives(
        spans: [TimeSpan] = [],
        dates: [Date] = []
    ) {
        let calendar = Calendar.autoupdatingCurrent
        var starts = Set(dates.map(calendar.startOfDay))
        for span in spans {
            var day = calendar.startOfDay(for: span.start)
            while day < span.end {
                starts.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day)
                else { break }
                day = next
            }
        }
        guard !starts.isEmpty else { return }
        snapshot.yearlyReports = snapshot.yearlyReports.compactMap { year in
            let days = year.days.filter { !starts.contains($0.span.start) }
            guard !days.isEmpty else { return nil }
            return ReviewArchiveHierarchy.year(
                span: year.span,
                days: days,
                asOf: .now,
                calendar: calendar
            )
        }
        lastReviewArchiveRefreshAt = nil
    }

    @discardableResult
    private func persistDeviceLocalSnapshot(force: Bool = false) async -> Bool {
        guard acceptsDataMutation() else { return false }
        guard !isSensorTimelineRefreshing else {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Device persistence blocked after repository load failure; preserving existing data"
            )
            return false
        }
        // Location and HealthKit callbacks can converge at the same moment.
        // Coalesce those device-only commits so one sensor tick does not
        // trigger duplicate disk writes, widget serialization and timeline
        // reload requests. The coalesced change must still reach disk, so a
        // trailing write is scheduled instead of being dropped.
        if !force, repositoryWriteTask != nil {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        if !force, let lastDeviceSnapshotPersistAt,
           Date.now.timeIntervalSince(lastDeviceSnapshotPersistAt) < 1.5 {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        pendingDeviceLocalPersistTask?.cancel()
        pendingDeviceLocalPersistTask = nil
        do {
            normalizeLocalRecordsIfNeeded()
            var value = snapshotForPersistence()
            value.updatedAt = .now
            var visibleValue = value
            visibleValue.memos = snapshot.memos
            let sourceRevision = snapshotRevision
            guard try await saveToRepository(
                value,
                expectedRevision: sourceRevision,
                requiresCurrentRevision: false
            ) else { return false }
            if snapshotRevision == sourceRevision {
                assignTimestampOnlySnapshot(visibleValue)
            }
            lastDeviceSnapshotPersistAt = .now
            publishWidgetPayload()
            return true
        } catch is CancellationError {
            if isSceneActive { scheduleTrailingDeviceLocalPersist() }
            return false
        } catch {
            userFacingError = AppModelMessage
                .sensorSaveFailed(error.localizedDescription).text()
            return false
        }
    }

    private func normalizeLocalRecordsIfNeeded() {
        guard needsLocalRecordNormalization else { return }
        if snapshot.actuals.contains(where: {
            $0.source.usesAutomaticClassification && !$0.isClassificationLocked
        }) {
            snapshot.actuals = ActivityClassificationLockEngine
                .lockingAutomaticClassifications(snapshot.actuals)
        }
        if snapshot.travel.contains(where: { !$0.isClassificationLocked }) {
            snapshot.travel = snapshot.travel.map { segment in
                var value = segment
                value.isClassificationLocked = true
                return value
            }
        }
        applyStoredActivityCorrections()
        needsLocalRecordNormalization = false
    }

    private func snapshotForPersistence() -> TaptionDataSnapshot {
        var value = snapshot
        value.memos.removeAll { pendingMapMemoIDs.contains($0.id) }
        return value
    }

    private func scheduleTrailingDeviceLocalPersist() {
        guard pendingDeviceLocalPersistTask == nil else { return }
        pendingDeviceLocalPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.pendingDeviceLocalPersistTask = nil
            await self.persistDeviceLocalSnapshot()
        }
    }
}

enum TaptionWatchDaySummaryFactory {
    static func make(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TaptionWatchDaySummary {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(86_400)
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let scheduled = plans.filter {
            $0.status != .skipped && $0.span.intersection(with: day) != nil
        }
        let recordedSpans: [TimeSpan] = actuals.compactMap {
            $0.span(asOf: date).intersection(with: day)
        }
        let activeCategoryIDs: Set<String> = [
            "movement",
            "exercise",
            "health",
        ]
        let activeSpans: [TimeSpan] = actuals.compactMap { actual -> TimeSpan? in
            guard activeCategoryIDs.contains(actual.categoryID) else {
                return nil
            }
            return actual.span(asOf: date).intersection(with: day)
        }
        return TaptionWatchDaySummary(
            date: dayStart,
            scheduledCount: scheduled.count,
            completedCount: scheduled.filter {
                $0.status == .completed
            }.count,
            recordedMinutes: minutes(in: recordedSpans),
            activeMinutes: minutes(in: activeSpans)
        )
    }

    private static func minutes(in spans: [TimeSpan]) -> Int {
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
        duration += current.duration
        return max(0, Int((duration / 60).rounded()))
    }
}

/// Error messages the app also matches on or tests by their leading sentence,
/// so the Korean and English wording live side by side.
enum AppModelMessage: Equatable, Sendable {
    case dataLoadFailed(String)
    case locationReadFailed(String)
    case sensorSaveFailed(String)
    case floorOutOfRange(lower: Int, upper: Int)

    func lead(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case .dataLoadFailed:
            AppLanguagePreference.text(
                korean: "저장된 데이터를 불러오지 못했습니다.",
                english: "Saved data could not be loaded.",
                preference: preference
            )
        case .locationReadFailed:
            AppLanguagePreference.text(
                korean: "위치 기록을 읽지 못했습니다.",
                english: "Could not read location records.",
                preference: preference
            )
        case .sensorSaveFailed:
            AppLanguagePreference.text(
                korean: "센서 기록을 저장하지 못했습니다.",
                english: "Could not save sensor records.",
                preference: preference
            )
        case let .floorOutOfRange(lower, upper):
            AppLanguagePreference.text(
                korean: "층수는 \(FloorLabel.korean(lower))부터 \(FloorLabel.korean(upper)) 사이로 입력해 주세요.",
                english: "Enter a floor between \(FloorLabel.english(lower)) and \(FloorLabel.english(upper)).",
                preference: preference
            )
        }
    }

    func text(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case let .dataLoadFailed(detail),
             let .locationReadFailed(detail),
             let .sensorSaveFailed(detail):
            "\(lead(preference: preference)) \(detail)"
        case .floorOutOfRange:
            lead(preference: preference)
        }
    }

    /// True for a load-failure message in either language, so recovery still
    /// clears it after the app language changed.
    static func isDataLoadFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return [AppLanguagePreference.korean, .english].contains {
            message.hasPrefix(dataLoadFailed("").lead(preference: $0))
        }
    }
}

extension PermissionState {
    var isGranted: Bool {
        self == .authorized || self == .limited
    }

    var settingsLabel: String {
        switch self {
        case .notDetermined:
            AppLanguagePreference.text(korean: "연결하기", english: "Connect")
        case .denied:
            AppLanguagePreference.text(korean: "권한 필요", english: "Permission needed")
        case .limited:
            AppLanguagePreference.text(korean: "일부 허용", english: "Partially allowed")
        case .authorized:
            AppLanguagePreference.text(korean: "연결됨", english: "Connected")
        case .unavailable:
            AppLanguagePreference.text(korean: "사용 불가", english: "Unavailable")
        }
    }
}

private extension TimeScale {
    init(timelineLevel: TimelineLevel) {
        switch timelineLevel {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .year
        }
    }
}

private extension CatCoat {
    init(catStyle: CatStyle) {
        switch catStyle {
        case .white: self = .white
        case .calico: self = .calico
        case .mackerel: self = .mackerel
        case .black: self = .black
        case .gray: self = .gray
        case .cheese: self = .cheese
        case .cow: self = .cow
        }
    }

    var catStyle: CatStyle {
        switch self {
        case .white: .white
        case .calico: .calico
        case .mackerel: .mackerel
        case .black: .black
        case .gray: .gray
        case .cheese: .cheese
        case .cow: .cow
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct TodaySensorRawExport: Codable, Sendable {
    let day: Date
    let isComplete: Bool
    let readings: [SensorReading]
    let travel: [TravelSegment]

    static func readings(_ source: [SensorReading], on date: Date,
        calendar: Calendar = .autoupdatingCurrent) -> [SensorReading] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return source.filter { $0.timestamp >= start && $0.timestamp < end }
    }
}


/// 걸음 측정 응답과 시간 초과 중 먼저 온 쪽으로 한 번만 이어 간다.
private final class PedometerResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?

    init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }

    func resume(_ value: Double?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
