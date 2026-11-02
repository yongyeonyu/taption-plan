import SwiftUI
import UIKit
import MapKit

@MainActor
final class TimelinePlayheadDetailGate {
    private let defaultInterval: TimeInterval = 1.0 / 20.0
    private var lastDeliveryUptime: TimeInterval = -.infinity
    private var pendingDate: Date?
    private var scheduledTask: Task<Void, Never>?

    func submit(
        _ date: Date,
        minimumInterval: TimeInterval? = nil,
        deliver: @escaping @MainActor (Date) -> Void
    ) {
        pendingDate = date
        let now = ProcessInfo.processInfo.systemUptime
        let interval = max(0.001, minimumInterval ?? defaultInterval)
        let remaining = interval - (now - lastDeliveryUptime)
        if remaining <= 0 {
            scheduledTask?.cancel()
            scheduledTask = nil
            deliverPending(using: deliver)
            return
        }
        guard scheduledTask == nil else { return }
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, remaining) * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.scheduledTask = nil
            self.deliverPending(using: deliver)
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
        pendingDate = nil
    }

    private func deliverPending(
        using deliver: @MainActor (Date) -> Void
    ) {
        guard let pendingDate else { return }
        self.pendingDate = nil
        lastDeliveryUptime = ProcessInfo.processInfo.systemUptime
        deliver(pendingDate)
    }
}

func playheadDetailInterval(for scale: TimeScale) -> TimeInterval {
    switch scale {
    case .day: 1.0 / 20.0
    case .week: 1.0 / 15.0
    case .month: 1.0 / 12.0
    case .year: 1.0 / 10.0
    }
}

@MainActor
final class TimelineMapFitGate {
    private var lastUptime: TimeInterval = -.infinity

    func permits(
        force: Bool,
        minimumInterval: TimeInterval = 1.0 / 30.0
    ) -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastUptime >= minimumInterval else {
            return false
        }
        lastUptime = uptime
        return true
    }
}

@MainActor
final class TimelineRelationshipGraphCache {
    struct Key: Equatable {
        let timelineRevision: UInt64
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
        let focusNodeID: String?
    }

    private var key: Key?
    private var graph: RecordRelationshipGraph?

    func value(
        for key: Key,
        build: () -> RecordRelationshipGraph
    ) -> RecordRelationshipGraph {
        if self.key == key, let graph {
            return graph
        }
        let graph = build()
        self.key = key
        self.graph = graph
        return graph
    }
}

@MainActor
final class TimelinePhotoClusterCache {
    private var timelineRevision: UInt64?
    private var clusters: [PhotoCluster] = []

    func value(
        timelineRevision: UInt64,
        photos: [PhotoMoment]
    ) -> [PhotoCluster] {
        if self.timelineRevision == timelineRevision {
            return clusters
        }
        clusters = PhotoClusterer.cluster(photos)
        self.timelineRevision = timelineRevision
        return clusters
    }

    func nearest(
        timelineRevision: UInt64,
        photos: [PhotoMoment],
        to date: Date,
        tolerance: TimeInterval
    ) -> PhotoCluster? {
        let clusters = value(
            timelineRevision: timelineRevision,
            photos: photos
        )
        guard !clusters.isEmpty else { return nil }

        let searchRadius = max(0, tolerance) + 20 * 60
        let lowerBound = date.addingTimeInterval(-searchRadius)
        let upperBound = date.addingTimeInterval(searchRadius)

        // PhotoClusterer returns chronological clusters. Find the first
        // possible representative with a lower-bound search instead of
        // filtering and sorting the entire photo library on every playhead
        // delivery.
        var low = 0
        var high = clusters.count
        while low < high {
            let middle = (low + high) / 2
            if clusters[middle].capturedAt < lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var best: PhotoCluster?
        var bestDistance = TimeInterval.infinity
        var index = low
        while index < clusters.count {
            let cluster = clusters[index]
            guard cluster.capturedAt <= upperBound else { break }
            guard let start = cluster.photos.first?.capturedAt,
                  let end = cluster.photos.last?.capturedAt,
                  start.addingTimeInterval(-tolerance) <= date,
                  date <= end.addingTimeInterval(tolerance) else {
                index += 1
                continue
            }
            let distance = abs(cluster.capturedAt.timeIntervalSince(date))
            if distance < bestDistance {
                best = cluster
                bestDistance = distance
            }
            index += 1
        }
        return best
    }
}

@MainActor
final class TimelinePlaceIndexCache {
    private var timelineRevision: UInt64?
    private var placesByID: [UUID: PlaceStay] = [:]
    private var placesByStart: [PlaceStay] = []
    private var placesMaxEnds: [TimeInterval] = []
    private var lastContainingPlace: PlaceStay?

    func place(
        id: UUID,
        timelineRevision: UInt64,
        places: [PlaceStay]
    ) -> PlaceStay? {
        prepare(
            timelineRevision: timelineRevision,
            places: places
        )
        return placesByID[id]
    }

    func values(
        timelineRevision: UInt64,
        places: [PlaceStay]
    ) -> [PlaceStay] {
        prepare(
            timelineRevision: timelineRevision,
            places: places
        )
        return placesByStart
    }

    func containing(
        date: Date,
        timelineRevision: UInt64,
        places: [PlaceStay]
    ) -> PlaceStay? {
        prepare(
            timelineRevision: timelineRevision,
            places: places
        )
        if let lastContainingPlace,
           lastContainingPlace.span.contains(date) {
            return lastContainingPlace
        }

        // Place stays are start-sorted. Find the newest stay that starts
        // before the playhead, then walk backwards only while an unusually
        // long stay could still overlap it. This replaces a full-place scan
        // on every 20 Hz playhead update.
        var low = 0
        var high = placesByStart.count
        while low < high {
            let middle = (low + high) / 2
            if placesByStart[middle].span.start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var index = low - 1
        while index >= 0 {
            let candidate = placesByStart[index]
            if candidate.span.contains(date) {
                lastContainingPlace = candidate
                return candidate
            }
            if index < placesMaxEnds.count,
               placesMaxEnds[index]
                    < date.timeIntervalSinceReferenceDate {
                break
            }
            index -= 1
        }
        lastContainingPlace = nil
        return nil
    }

    private func prepare(
        timelineRevision: UInt64,
        places: [PlaceStay]
    ) {
        guard self.timelineRevision != timelineRevision else { return }
        self.timelineRevision = timelineRevision
        placesByID = Dictionary(
            places.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        placesByStart = places.sorted {
            if $0.span.start == $1.span.start {
                return $0.span.end < $1.span.end
            }
            return $0.span.start < $1.span.start
        }
        placesMaxEnds = prefixMaximumEnds(in: placesByStart)
        lastContainingPlace = nil
    }

    private func prefixMaximumEnds(
        in values: [PlaceStay]
    ) -> [TimeInterval] {
        var maximum = -TimeInterval.infinity
        return values.map { place in
            maximum = max(
                maximum,
                place.span.end.timeIntervalSinceReferenceDate
            )
            return maximum
        }
    }
}

@MainActor
final class TimelineSelectionIndexCache {
    private var timelineRevision: UInt64?
    private var travel: [TravelSegment] = []
    private var eventPlans: [PlanRecord] = []
    private var calendarEvents: [CalendarRecord] = []
    private var routinePlans: [PlanRecord] = []
    private var automaticActuals: [ActualRecord] = []
    private var actionPlans: [PlanRecord] = []
    private var travelMaxEnds: [TimeInterval] = []
    private var eventPlanMaxEnds: [TimeInterval] = []
    private var calendarEventMaxEnds: [TimeInterval] = []
    private var routinePlanMaxEnds: [TimeInterval] = []
    private var automaticActualMaxEnds: [TimeInterval] = []
    private var actionPlanMaxEnds: [TimeInterval] = []
    private var categoryNames: [String: String] = [:]
    private var lastTravel: TravelSegment?
    private var lastEventPlan: PlanRecord?
    private var lastCalendarEvent: CalendarRecord?
    private var lastActionPlan: PlanRecord?

    func prepare(
        timelineRevision: UInt64,
        plans: [PlanRecord],
        travel: [TravelSegment],
        calendarEvents: [CalendarRecord],
        categories: [CategoryDefinition],
        actuals: [ActualRecord] = []
    ) {
        guard self.timelineRevision != timelineRevision else { return }
        self.timelineRevision = timelineRevision
        self.travel = travel
        self.eventPlans = plans.filter {
            $0.categoryID == "event" && $0.parentID == nil
        }
        self.calendarEvents = calendarEvents
        self.routinePlans = plans.filter {
            $0.origin == .repeatRule && $0.status != .skipped
        }
        self.automaticActuals = actuals.filter {
            if TaptionProductScope.automaticLoggingOnly {
                return $0.source == .healthKit
                    || $0.source == .appleWatch
            }
            return $0.categoryID == "sleep"
                || $0.categoryID == "activity"
                || $0.source == .healthKit
                || $0.source == .appleWatch
        }
        self.actionPlans = plans.filter {
            $0.categoryID != "event"
                && $0.parentID == nil
                && !GoalRecordPolicy.isGoal($0)
        }
        self.travel.sort { $0.span.start < $1.span.start }
        self.eventPlans.sort { $0.span.start < $1.span.start }
        self.calendarEvents.sort { $0.span.start < $1.span.start }
        self.routinePlans.sort { $0.span.start < $1.span.start }
        self.automaticActuals.sort { $0.startedAt < $1.startedAt }
        self.actionPlans.sort { $0.span.start < $1.span.start }
        self.travelMaxEnds = prefixMaximumEnds(in: self.travel, span: \.span)
        self.eventPlanMaxEnds = prefixMaximumEnds(in: self.eventPlans, span: \.span)
        self.calendarEventMaxEnds = prefixMaximumEnds(in: self.calendarEvents, span: \.span)
        self.routinePlanMaxEnds = prefixMaximumEnds(in: self.routinePlans, span: \.span)
        self.automaticActualMaxEnds = prefixMaximumEnds(
            in: self.automaticActuals,
            span: { $0.span() }
        )
        self.actionPlanMaxEnds = prefixMaximumEnds(in: self.actionPlans, span: \.span)
        lastTravel = nil
        lastEventPlan = nil
        lastCalendarEvent = nil
        lastActionPlan = nil
        self.categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func travel(containing date: Date) -> TravelSegment? {
        if let lastTravel, lastTravel.span.contains(date) {
            return lastTravel
        }
        let value = nearestContaining(
            date,
            in: travel,
            prefixMaximumEnds: travelMaxEnds,
            span: \.span
        )
        lastTravel = value
        return value
    }

    func eventPlan(containing date: Date) -> PlanRecord? {
        if let lastEventPlan, lastEventPlan.span.contains(date) {
            return lastEventPlan
        }
        let value = nearestContaining(
            date,
            in: eventPlans,
            prefixMaximumEnds: eventPlanMaxEnds,
            span: \.span
        )
        lastEventPlan = value
        return value
    }

    func calendarEvent(containing date: Date) -> CalendarRecord? {
        if let lastCalendarEvent, lastCalendarEvent.span.contains(date) {
            return lastCalendarEvent
        }
        let value = nearestContaining(
            date,
            in: calendarEvents,
            prefixMaximumEnds: calendarEventMaxEnds,
            span: \.span
        )
        lastCalendarEvent = value
        return value
    }

    func actionPlan(containing date: Date) -> PlanRecord? {
        if let lastActionPlan, lastActionPlan.span.contains(date) {
            return lastActionPlan
        }
        let value = nearestContaining(
            date,
            in: actionPlans,
            prefixMaximumEnds: actionPlanMaxEnds,
            span: \.span
        )
        lastActionPlan = value
        return value
    }

    func routinePlan(containing date: Date) -> PlanRecord? {
        nearestContaining(
            date,
            in: routinePlans,
            prefixMaximumEnds: routinePlanMaxEnds,
            span: \.span
        )
    }

    func categoryName(for categoryID: String) -> String? {
        categoryNames[categoryID]
    }

    private func nearestContaining<Value>(
        _ date: Date,
        in values: [Value],
        prefixMaximumEnds: [TimeInterval],
        span: (Value) -> TimeSpan
    ) -> Value? {
        guard !values.isEmpty else { return nil }

        // The collections are start-sorted. Find the last item that starts
        // before the playhead, then walk backwards only through overlapping
        // intervals instead of scanning every record at 20 Hz.
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if span(values[middle]).start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var index = low - 1
        while index >= 0 {
            let candidate = values[index]
            let candidateSpan = span(candidate)
            if candidateSpan.contains(date) {
                return candidate
            }
            // Older records normally end before this point. The prefix maximum
            // lets us stop safely even when one unusually long interval exists
            // elsewhere in the collection.
            if index < prefixMaximumEnds.count,
               prefixMaximumEnds[index]
                    < date.timeIntervalSinceReferenceDate {
                break
            }
            index -= 1
        }
        return nil
    }

    private func prefixMaximumEnds<Value>(
        in values: [Value],
        span: (Value) -> TimeSpan
    ) -> [TimeInterval] {
        var maximum = -TimeInterval.infinity
        return values.map { value in
            maximum = max(
                maximum,
                span(value).end.timeIntervalSinceReferenceDate
            )
            return maximum
        }
    }
}

@MainActor
final class TimelinePlanIndexCache {
    private var timelineRevision: UInt64?
    private var plansByID: [UUID: PlanRecord] = [:]

    func plan(
        id: UUID,
        timelineRevision: UInt64,
        plans: [PlanRecord]
    ) -> PlanRecord? {
        if self.timelineRevision != timelineRevision {
            self.timelineRevision = timelineRevision
            plansByID = Dictionary(
                plans.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return plansByID[id]
    }
}

@MainActor
final class TimelineWeatherContextCache {
    private struct Key: Equatable {
        let snapshotRevision: UInt64
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
        let selectedDate: TimeInterval
    }

    private var key: Key?
    private var cachedWeather: WeatherContext?

    func nearest(
        snapshotRevision: UInt64,
        weather: [WeatherContext],
        inside span: TimeSpan,
        to date: Date
    ) -> WeatherContext? {
        let key = Key(
            snapshotRevision: snapshotRevision,
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            selectedDate: date.timeIntervalSinceReferenceDate
        )
        if self.key == key {
            return cachedWeather
        }
        let value = weather
            .filter {
                weatherTimelineSpan($0).intersection(with: span) != nil
            }
            .min {
                abs($0.observedAt.timeIntervalSince(date))
                    < abs($1.observedAt.timeIntervalSince(date))
            }
        self.key = key
        cachedWeather = value
        return value
    }
}

@MainActor
final class TimelineRoutePresentationCache {
    struct Key: Equatable {
        let timelineRevision: UInt64
        let readingsCount: Int
        let firstReadingID: UUID?
        let lastReadingID: UUID?
        let firstReadingTimestamp: Date?
        let lastReadingTimestamp: Date?
        let liveRouteUpdatedAt: Date?
    }

    private struct SegmentQuery: Hashable {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
        let selectedTravelID: UUID?
    }

    private struct CoordinateQuery: Hashable {
        let segmentID: UUID
        let includeImprecise: Bool
    }

    private struct SpanQuery: Hashable {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
    }

    private var baseKey: Key?
    private var segmentValues: [SegmentQuery: [TravelSegment]] = [:]
    private var coordinateValues: [CoordinateQuery: [CLLocationCoordinate2D]] = [:]
    private var fallbackValues: [SpanQuery: [CLLocationCoordinate2D]] = [:]
    private var contextValues: [SpanQuery: [TravelSegment]] = [:]
    private var lastPlayheadSpan: (start: TimeInterval, end: TimeInterval)?
    private var lastPlayheadSegments: [TravelSegment] = []
    private var indexedTimelineRevision: UInt64?
    private var travelByStart: [TravelSegment] = []
    private var travelMaxEnds: [TimeInterval] = []

    func segments(
        for key: Key,
        span: TimeSpan,
        playheadDate: Date?,
        selectedTravelID: UUID?,
        travel: [TravelSegment],
        build: () -> [TravelSegment]
    ) -> [TravelSegment] {
        prepare(for: key)
        if playheadDate == nil || selectedTravelID != nil {
            lastPlayheadSpan = nil
            lastPlayheadSegments.removeAll(keepingCapacity: true)
        }
        // While scrubbing inside one travel segment, the answer is stable.
        // Reuse it until every previously returned segment no longer contains
        // the new playhead, then let the normal policy recompute at the
        // boundary. This avoids filtering the full travel list at 20 Hz.
        // Playhead dates are deliberately not inserted into the dictionary:
        // a continuous drag can produce thousands of distinct Date keys and
        // retain them for the lifetime of the detail panel.
        if let playheadDate,
           selectedTravelID == nil,
           let lastPlayheadSpan,
           lastPlayheadSpan.start == span.start.timeIntervalSinceReferenceDate,
           lastPlayheadSpan.end == span.end.timeIntervalSinceReferenceDate,
           !lastPlayheadSegments.isEmpty,
            lastPlayheadSegments.allSatisfy({
                $0.span.contains(playheadDate)
            }) {
            return lastPlayheadSegments
        }

        if playheadDate != nil, selectedTravelID == nil {
            let value = segments(containing: playheadDate!, travel: travel)
            lastPlayheadSpan = (
                span.start.timeIntervalSinceReferenceDate,
                span.end.timeIntervalSinceReferenceDate
            )
            lastPlayheadSegments = value
            return value
        }

        let query = SegmentQuery(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            selectedTravelID: selectedTravelID
        )
        if let cached = segmentValues[query] {
            return cached
        }
        let value = build()
        segmentValues[query] = value
        return value
    }

    private func segments(
        containing date: Date,
        travel: [TravelSegment]
    ) -> [TravelSegment] {
        if indexedTimelineRevision == baseKey?.timelineRevision {
            // The timeline revision is stable while a playhead is moving.
            // Reuse the sorted interval index instead of sorting sensor
            // segments on every touch delivery.
        } else {
            travelByStart = travel.sorted {
                if $0.span.start == $1.span.start {
                    return $0.span.end < $1.span.end
                }
                return $0.span.start < $1.span.start
            }
            travelMaxEnds = prefixMaximumEnds(in: travelByStart)
            indexedTimelineRevision = baseKey?.timelineRevision
        }

        guard !travelByStart.isEmpty else { return [] }

        // Find the first segment whose start is after the playhead. Walk
        // backwards for overlaps, then forwards for segments starting at the
        // same instant. Most timelines visit one segment, so this stays
        // logarithmic with a tiny overlap scan.
        var low = 0
        var high = travelByStart.count
        while low < high {
            let middle = (low + high) / 2
            if travelByStart[middle].span.start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var matches: [TravelSegment] = []
        var index = low - 1
        while index >= 0 {
            let candidate = travelByStart[index]
            if candidate.span.contains(date) {
                matches.append(candidate)
            }
            if index < travelMaxEnds.count,
               travelMaxEnds[index]
                    < date.timeIntervalSinceReferenceDate {
                break
            }
            index -= 1
        }

        index = low
        while index < travelByStart.count,
              travelByStart[index].span.start <= date {
            let candidate = travelByStart[index]
            if candidate.span.contains(date) {
                matches.append(candidate)
            }
            index += 1
        }
        guard matches.count > 1 else { return matches }
        return matches.sorted { $0.span.start < $1.span.start }
    }

    private func prefixMaximumEnds(
        in values: [TravelSegment]
    ) -> [TimeInterval] {
        var maximum = -TimeInterval.infinity
        return values.map { segment in
            maximum = max(
                maximum,
                segment.span.end.timeIntervalSinceReferenceDate
            )
            return maximum
        }
    }

    func coordinates(
        for key: Key,
        segmentID: UUID,
        includeImprecise: Bool,
        build: () -> [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        prepare(for: key)
        let query = CoordinateQuery(
            segmentID: segmentID,
            includeImprecise: includeImprecise
        )
        if let cached = coordinateValues[query] {
            return cached
        }
        let value = build()
        coordinateValues[query] = value
        return value
    }

    func fallbackCoordinates(
        for key: Key,
        span: TimeSpan,
        build: () -> [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        prepare(for: key)
        let query = SpanQuery(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate
        )
        if let cached = fallbackValues[query] {
            return cached
        }
        let value = build()
        fallbackValues[query] = value
        return value
    }

    /// 배경 경로는 기간이 같으면 답도 같다. 재생 머리가 20Hz로 움직여도
    /// 기간은 그대로이므로 이동 목록을 다시 훑지 않는다.
    func contextSegments(
        for key: Key,
        span: TimeSpan,
        build: () -> [TravelSegment]
    ) -> [TravelSegment] {
        prepare(for: key)
        let query = SpanQuery(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate
        )
        if let cached = contextValues[query] {
            return cached
        }
        let value = build()
        contextValues[query] = value
        return value
    }

    private func prepare(for key: Key) {
        guard baseKey != key else { return }
        baseKey = key
        segmentValues.removeAll(keepingCapacity: true)
        coordinateValues.removeAll(keepingCapacity: true)
        fallbackValues.removeAll(keepingCapacity: true)
        contextValues.removeAll(keepingCapacity: true)
        lastPlayheadSpan = nil
        lastPlayheadSegments.removeAll(keepingCapacity: true)
    }
}

struct TimelineRouteReadingSignature: Equatable {
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
    let firstTimestamp: Date?
    let lastTimestamp: Date?
}

@MainActor
final class TimelineDetailDataCache {
    struct Key: Equatable {
        let timelineRevision: UInt64
        let contentStart: TimeInterval
        let contentEnd: TimeInterval
        let displayStart: TimeInterval
        let displayEnd: TimeInterval
        let memoStart: TimeInterval
        let memoEnd: TimeInterval
        let playheadMinute: Int?
        let selectedPlanID: UUID?
        let selectedActualID: UUID?
        let selectedTravelID: UUID?
        let selectedRecordNodeID: String?
        let selectedCategoryID: String?
    }

    struct Value {
        let actionPlans: [PlanRecord]
        let selectedManualActionPlan: PlanRecord?
        let places: [PlaceStay]
        let travel: [TravelSegment]
        let movementActuals: [ActualRecord]
        let sleepPlans: [PlanRecord]
        let activityPlans: [PlanRecord]
        let sleepActuals: [ActualRecord]
        let activityActuals: [ActualRecord]
        let appUsageActuals: [ActualRecord]
        let weather: [WeatherContext]
        let selectedActual: ActualRecord?
        let eventPlans: [PlanRecord]
        let calendarEvents: [CalendarRecord]
        let memos: [ActionMemo]

        static let empty = Value(
            actionPlans: [],
            selectedManualActionPlan: nil,
            places: [],
            travel: [],
            movementActuals: [],
            sleepPlans: [],
            activityPlans: [],
            sleepActuals: [],
            activityActuals: [],
            appUsageActuals: [],
            weather: [],
            selectedActual: nil,
            eventPlans: [],
            calendarEvents: [],
            memos: []
        )
    }

    private var key: Key?
    private var cachedValue: Value?

    func value(
        for key: Key,
        build: () -> Value
    ) -> Value {
        if self.key == key, let cachedValue {
            return cachedValue
        }
        let value = build()
        self.key = key
        cachedValue = value
        return value
    }
}

/// Immutable NLE render snapshot. Source data is versioned by
/// `timelineRevision`; viewport gestures only reproject these tracks.
struct NLETimelineRenderSnapshot {
    let documentRevision: UInt64
    let rows: [TimelineRowModel]
    let axisMarkers: [TimelineAxisMarker]
    let photoClusters: [PhotoCluster]
    let summaryBuckets: [SummaryBucket]
    let summaryColors: [SummaryColor]
    let contentHeight: CGFloat
}

struct NLETimelineRenderKey: Equatable {
    let documentRevision: UInt64
    let scale: TimeScale
    let isGroup: Bool
    let selectedGroupPlanID: UUID?
    let spanStart: TimeInterval
    let spanEnd: TimeInterval
}

/// 시간표는 멈춰 있을 때의 좁은 구간과 드래그용 넓은 구간을 번갈아 쓴다.
/// 일·주·월 해상도와 직전 드래그 창이 서로 밀려나지 않도록 네 벌을 남겨 둔다.
@MainActor
final class NLETimelineRenderCache {
    private var entries: [(
        key: NLETimelineRenderKey,
        snapshot: NLETimelineRenderSnapshot
    )] = []

    func value(
        for key: NLETimelineRenderKey,
        build: () -> NLETimelineRenderSnapshot
    ) -> NLETimelineRenderSnapshot {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.snapshot
        }
        let snapshot = build()
        entries.insert((key, snapshot), at: 0)
        if entries.count > 4 {
            entries.removeLast(entries.count - 4)
        }
        return snapshot
    }
}

@MainActor
final class TimelineBoardDataIndexCache {
    private var revision: UInt64?
    private var cachedIndex: TimelineBoardDataIndex?

    func value(
        for revision: UInt64,
        build: () -> TimelineBoardDataIndex
    ) -> TimelineBoardDataIndex {
        if self.revision == revision, let cachedIndex {
            return cachedIndex
        }
        let index = build()
        self.revision = revision
        cachedIndex = index
        return index
    }
}

struct TimelineSummaryKey: Equatable {
    let timelineRevision: UInt64
    let childLevel: TimelineLevel
    let spanStart: TimeInterval
    let spanEnd: TimeInterval
}

@MainActor
final class TimelineSummaryCache {
    private var key: TimelineSummaryKey?
    private var buckets: [SummaryBucket] = []

    func value(
        for key: TimelineSummaryKey,
        build: () -> [SummaryBucket]
    ) -> [SummaryBucket] {
        if self.key == key { return buckets }
        let buckets = build()
        self.key = key
        self.buckets = buckets
        return buckets
    }
}

struct ContinuousMagnifyOrigin {
    let duration: TimeInterval
    let anchorDate: Date
    let anchor: Double
}

final class TimelineGestureMetrics {
    private(set) var kind: String?
    private var startedUptime: TimeInterval = 0
    private(set) var inputSamples = 0
    private(set) var renderedSamples = 0

    func begin(_ kind: String) {
        guard self.kind == nil else { return }
        self.kind = kind
        startedUptime = ProcessInfo.processInfo.systemUptime
        inputSamples = 0
        renderedSamples = 0
    }

    func inputSample() {
        guard kind != nil else { return }
        inputSamples += 1
    }

    func renderedSample() {
        guard kind != nil else { return }
        renderedSamples += 1
    }

    func finish() -> [String: String]? {
        guard let kind else { return nil }
        let duration = max(
            0,
            ProcessInfo.processInfo.systemUptime - startedUptime
        )
        let reduction = inputSamples > 0
            ? Int(
                (1 - Double(renderedSamples) / Double(inputSamples)) * 100
            )
            : 0
        let fields = [
            "kind": kind,
            "input_samples": String(inputSamples),
            "rendered_samples": String(renderedSamples),
            "reduction_percent": String(max(0, reduction)),
            "duration_ms": String(Int(duration * 1_000)),
        ]
        self.kind = nil
        inputSamples = 0
        renderedSamples = 0
        return fields
    }
}
