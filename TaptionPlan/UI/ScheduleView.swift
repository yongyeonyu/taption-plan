import SwiftUI
import UIKit
import MapKit

private let scheduleLabelColumnWidth: CGFloat = 64
private let ganttTableLineColor = Color.tpLine.opacity(0.30)
private let detailPanelCollapsedHeight: CGFloat = 300
private let detailPanelMinimumHeight: CGFloat = 220

#if DEBUG
/// Debug-only display-link probe for physical-device frame evidence.
///
/// Instruments can attach to the process, but on some iOS/Xcode combinations
/// it produces an empty trace package.  This probe stays out of release
/// builds and writes a small rolling summary to the app container instead.
/// It never participates in timeline state or layout calculations.
private final class TimelineFrameBudgetProbe: NSObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var intervals: [Double] = []
    private var lastWriteAt = ProcessInfo.processInfo.systemUptime

    func start() {
        guard displayLink == nil else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        lastWriteAt = startedAt
        displayLink = CADisplayLink(
            target: self,
            selector: #selector(displayLinkTick(_:))
        )
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        writeSummary(force: true)
        lastTimestamp = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        if let lastTimestamp {
            let interval = link.timestamp - lastTimestamp
            if interval > 0, interval < 1 {
                intervals.append(interval)
                if intervals.count > 600 {
                    intervals.removeFirst(intervals.count - 600)
                }
            }
        }
        lastTimestamp = link.timestamp
        writeSummary(force: false)
    }

    private func writeSummary(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWriteAt >= 5 else { return }
        lastWriteAt = now
        guard !intervals.isEmpty else { return }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[
            min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        ]
        let nominal = 1.0 / 60.0
        let dropped = intervals.filter {
            $0 > nominal * 1.5
        }.count
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "elapsed": now - startedAt,
            "samples": intervals.count,
            "medianFrameMs": median * 1_000,
            "p95FrameMs": p95 * 1_000,
            "maxFrameMs": (sorted.last ?? 0) * 1_000,
            "droppedOver25ms": dropped,
        ]

        do {
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("TaptionLogs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent(
                "FrameBudget-debug.jsonl"
            )
            let line = try JSONSerialization.data(
                withJSONObject: payload,
                options: []
            )
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } else {
                var firstLine = line
                firstLine.append(0x0A)
                try firstLine.write(to: file)
            }
        } catch {
            // Diagnostics must never affect the timeline render path.
        }
    }
}

private struct TimelineFrameBudgetProbeView: UIViewRepresentable {
    final class Coordinator {
        let probe = TimelineFrameBudgetProbe()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.probe.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(
        _ uiView: UIView,
        coordinator: Coordinator
    ) {
        coordinator.probe.stop()
    }
}
#endif

private struct TimelineAxisMarker: Identifiable {
    let id: String
    let date: Date?
    let fraction: Double
    let label: String
    let isCurrent: Bool
    let holidayName: String?

    init(
        id: String,
        date: Date? = nil,
        fraction: Double,
        label: String,
        isCurrent: Bool,
        holidayName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.fraction = fraction
        self.label = label
        self.isCurrent = isCurrent
        self.holidayName = holidayName
    }
}

private enum TimelineDetailSection: String, CaseIterable, Identifiable {
    case schedule = "일정"
    case location = "위치"
    case movement = "이동"
    case sleep = "수면"
    case activity = "활동"
    case appUsage = "앱"
    case weather = "날씨"
    case routine = "루틴"
    case action = "액션·메모"
    case photo = "사진"
    case event = "이벤트"
    case map = "지도"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .schedule: "calendar"
        case .location: "mappin.and.ellipse"
        case .movement: "figure.walk.motion"
        case .sleep: "moon.zzz"
        case .activity: "figure.run"
        case .appUsage: "app.badge.clock"
        case .weather: "cloud.sun"
        case .routine: "repeat.circle"
        case .action: "checklist.checked"
        case .photo: "photo.on.rectangle"
        case .event: "sparkles"
        case .map: "map"
        }
    }

    static let defaultOrder: [Self] = [
        .schedule,
        .location,
        .movement,
        .sleep,
        .activity,
        .appUsage,
        .weather,
        .photo,
        .map,
        .routine,
        .action,
        .event,
    ]
}

private func weatherTimelineSpan(_ context: WeatherContext) -> TimeSpan {
    WeatherTimelineEngine.span(for: context)
}

private func automaticSpanThroughNow(
    _ span: TimeSpan,
    asOf now: Date = .now
) -> TimeSpan? {
    guard span.start <= now else { return nil }
    return TimeSpan(start: span.start, end: min(span.end, now))
}

private func weatherTimelineTitle(_ context: WeatherContext) -> String {
    let air = context.airQuality.map {
        " · 미세 " + $0.overallGrade.displayName
    } ?? ""
    return Int(context.temperatureCelsius.rounded()).formatted()
        + "° · " + context.condition + air
}

private func weatherTimelineDetail(_ context: WeatherContext) -> String {
    var values = [
        "자동 날씨",
        context.observedAt.formatted(date: .omitted, time: .shortened),
    ]
    if let air = context.airQuality {
        values.append(
            "PM10 "
                + Int(air.pm10MicrogramsPerCubicMeter.rounded()).formatted()
                + " · PM2.5 "
                + Int(air.pm25MicrogramsPerCubicMeter.rounded()).formatted()
        )
    }
    return values.joined(separator: " · ")
}

private struct TimelineSelection: Equatable {
    let title: String
    let span: TimeSpan
    let planID: UUID?
    let actualID: UUID?
    let travelID: UUID?
    let recordNodeID: String?
    let isRoute: Bool
    let categoryID: String?
    let categoryName: String?

    init(
        title: String,
        span: TimeSpan,
        planID: UUID?,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) {
        self.title = title
        self.span = span
        self.planID = planID
        self.actualID = actualID
        self.travelID = travelID
        self.recordNodeID = recordNodeID
        self.isRoute = isRoute
        self.categoryID = categoryID
        self.categoryName = categoryName
    }
}

/// Keeps every detail card on the same instant as the red playhead.  The
/// timeline and the detail panel used to run separate containment checks,
/// which left the panel empty when an automatic record ended on a boundary.
private enum TimelinePlayheadSynchronizer {
    struct Match {
        let plans: [PlanRecord]
        let actuals: [ActualRecord]
        let automaticActuals: [ActualRecord]
        let places: [PlaceStay]
        let travel: [TravelSegment]
        let calendarEvents: [CalendarRecord]
        let weather: [WeatherContext]
        let photos: [PhotoCluster]

        var hasTimelineItem: Bool {
            !plans.isEmpty
                || !actuals.isEmpty
                || !places.isEmpty
                || !travel.isEmpty
                || !calendarEvents.isEmpty
                || !weather.isEmpty
                || !photos.isEmpty
        }
    }

    enum Direction {
        case forward
        case backward
    }

    static func contains(
        _ span: TimeSpan,
        at date: Date,
        tolerance: TimeInterval = 1
    ) -> Bool {
        date >= span.start.addingTimeInterval(-tolerance)
            && date <= span.end.addingTimeInterval(tolerance)
    }

    static func match(
        at date: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        calendarEvents: [CalendarRecord],
        weather: [WeatherContext],
        photos: [PhotoCluster] = [],
        photoTolerance: TimeInterval = 0
    ) -> Match {
        let isFuture = date > .now
        let actualValues = isFuture
            ? []
            : actuals.filter {
                contains($0.span(asOf: max(Date.now, date)), at: date)
            }
        let automaticValues = actualValues.filter {
            switch $0.source {
            case .healthKit, .appleWatch, .motion, .location, .media, .call,
                 .appUsage:
                true
            default:
                false
            }
        }
        return Match(
            plans: plans.filter {
                contains($0.span, at: date)
                    && !GoalRecordPolicy.isGoal($0)
            },
            actuals: actualValues,
            automaticActuals: automaticValues,
            places: isFuture
                ? []
                : places.filter { contains($0.span, at: date) },
            travel: isFuture
                ? []
                : travel.filter { contains($0.span, at: date) },
            calendarEvents: calendarEvents.filter {
                contains($0.span, at: date)
            },
            weather: isFuture
                ? []
                : weather.filter {
                    contains(
                        weatherTimelineSpan($0),
                        at: date,
                        tolerance: 2
                    )
                },
            photos: isFuture
                ? []
                : photos.filter { cluster in
                    cluster.photos.contains {
                        abs($0.capturedAt.timeIntervalSince(date))
                            <= photoTolerance
                    }
                }
        )
    }

    static func snapIfNeeded(
        date: Date,
        direction: Direction?,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        calendarEvents: [CalendarRecord],
        weather: [WeatherContext],
        photos: [PhotoCluster]
    ) -> Date {
        let match = match(
            at: date,
            plans: plans,
            actuals: actuals,
            places: places,
            travel: travel,
            calendarEvents: calendarEvents,
            weather: weather,
            photos: photos
        )
        guard !match.hasTimelineItem else { return date }

        let spans = plans
            .filter { !GoalRecordPolicy.isGoal($0) }
            .map(\.span)
            + actuals.map { $0.span(asOf: max(Date.now, date)) }
            + places.map(\.span)
            + travel.map(\.span)
            + calendarEvents.map(\.span)
            + weather.map { weatherTimelineSpan($0) }
            + photos.map(\.detailSpan)
        guard !spans.isEmpty else { return date }

        let ordered = spans.sorted { $0.start < $1.start }
        switch direction {
        case .forward:
            return ordered.first(where: { $0.start > date })?.start
                ?? date
        case .backward:
            return ordered.last(where: { $0.end < date })?.end
                ?? date
        case nil:
            return ordered.min {
                abs($0.start.timeIntervalSince(date))
                    < abs($1.start.timeIntervalSince(date))
            }?.start ?? date
        }
    }
}

private func watchBehavior(_ actual: ActualRecord) -> WatchBehaviorKind? {
    actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:))
}

private func isMovementActual(_ actual: ActualRecord) -> Bool {
    if actual.categoryID == "movement" { return true }
    if watchBehavior(actual)?.isMovement == true { return true }
    let title = actual.title.lowercased()
    return [
        "걷기", "걷", "달리기", "달리", "자전거", "차량", "자동차",
        "버스", "지하철", "택시", "기차", "비행기", "배", "이동",
    ].contains { title.contains($0) }
}

private func movementActualTitle(_ actual: ActualRecord) -> String {
    MovementPresentation.title(for: actual)
}

private func movementActualSymbol(_ actual: ActualRecord) -> String {
    MovementPresentation.symbol(for: actual)
}

private func restActualTitle(_ actual: ActualRecord) -> String {
    switch watchBehavior(actual) {
    case .stationary: "휴식 1"
    case .sitting: "휴식 2"
    case .standing: "휴식 3"
    case .lying: "휴식 4"
    default:
        actual.title.localizedCaseInsensitiveContains("휴식")
            || actual.title.localizedCaseInsensitiveContains("정지")
            ? "휴식 1"
            : actual.title
    }
}

private func timelineWeatherSelection(
    _ context: WeatherContext
) -> TimelineSelection {
    TimelineSelection(
        title: weatherTimelineTitle(context),
        span: weatherTimelineSpan(context),
        planID: nil,
        recordNodeID: "automatic.weather.\(context.id.uuidString)",
        isRoute: false,
        categoryID: "weather",
        categoryName: "날씨"
    )
}

private func timelineWeather(
    at date: Date,
    in contexts: [WeatherContext]
) -> WeatherContext? {
    contexts
        .filter { weatherTimelineSpan($0).contains(date) }
        .min {
            abs($0.observedAt.timeIntervalSince(date))
                < abs($1.observedAt.timeIntervalSince(date))
        }
}

@MainActor
private final class TimelinePlayheadDetailGate {
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

private func playheadDetailInterval(for scale: TimeScale) -> TimeInterval {
    switch scale {
    case .day: 1.0 / 20.0
    case .week: 1.0 / 15.0
    case .month: 1.0 / 12.0
    case .year: 1.0 / 10.0
    }
}

@MainActor
private final class TimelineMapFitGate {
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
private final class TimelineRelationshipGraphCache {
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
private final class TimelinePhotoClusterCache {
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
private final class TimelinePlaceIndexCache {
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
            uniqueKeysWithValues: places.map { ($0.id, $0) }
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
private final class TimelineSelectionIndexCache {
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

    func automaticActual(containing date: Date) -> ActualRecord? {
        nearestContaining(
            date,
            in: automaticActuals,
            prefixMaximumEnds: automaticActualMaxEnds,
            span: { $0.span() }
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
private final class TimelinePlanIndexCache {
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
private final class TimelineWeatherContextCache {
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
private final class TimelineRoutePresentationCache {
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

    private struct FallbackQuery: Hashable {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
    }

    private var baseKey: Key?
    private var segmentValues: [SegmentQuery: [TravelSegment]] = [:]
    private var coordinateValues: [CoordinateQuery: [CLLocationCoordinate2D]] = [:]
    private var fallbackValues: [FallbackQuery: [CLLocationCoordinate2D]] = [:]
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
        let query = FallbackQuery(
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

    private func prepare(for key: Key) {
        guard baseKey != key else { return }
        baseKey = key
        segmentValues.removeAll(keepingCapacity: true)
        coordinateValues.removeAll(keepingCapacity: true)
        fallbackValues.removeAll(keepingCapacity: true)
        lastPlayheadSpan = nil
        lastPlayheadSegments.removeAll(keepingCapacity: true)
    }
}

private struct TimelineRouteReadingSignature: Equatable {
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
    let firstTimestamp: Date?
    let lastTimestamp: Date?
}

@MainActor
private final class TimelineDetailDataCache {
    struct Key: Equatable {
        let timelineRevision: UInt64
        let contentStart: TimeInterval
        let contentEnd: TimeInterval
        let displayStart: TimeInterval
        let displayEnd: TimeInterval
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
            calendarEvents: []
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

private extension TimelineSelection {
    /// Memo identity follows the concrete timeline record, not its category.
    /// This prevents two sleep/activity/location blocks on the same day from
    /// sharing the same note storage.
    var memoTargetID: String? {
        if let recordNodeID, recordNodeID.hasPrefix("automatic.") {
            return recordNodeID
        }
        if let actualID {
            return "automatic.actual.\(actualID.uuidString)"
        }
        if let travelID {
            return "automatic.travel.\(travelID.uuidString)"
        }
        if let planID {
            return "plan.\(planID.uuidString)"
        }
        return recordNodeID
    }

    var preferredDetailSection: TimelineDetailSection {
        switch categoryID {
        case "location":
            return .location
        case "movement":
            return .movement
        case "sleep":
            return .sleep
        case "activity":
            return .activity
        case "weather":
            return .weather
        case "exercise", "workout":
            return .activity
        case "photo":
            return .photo
        case "event":
            return .event
        case "schedule", "calendar":
            return .schedule
        default:
            return isRoute ? .map : .action
        }
    }
}

private extension PhotoCluster {
    var detailSpan: TimeSpan {
        // PhotoClusterer keeps each cluster chronological. Avoid allocating
        // and sorting a second date array every time the detail panel asks
        // for the selected photo span.
        let start = photos.first?.capturedAt ?? capturedAt
        let end = photos.last?.capturedAt ?? capturedAt
        return TimeSpan(
            start: start,
            end: max(start.addingTimeInterval(60), end)
        )
    }
}

struct TwoFingerDoubleTapAttachment: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onRecognized = onRecognized
        uiView.installRecognizerIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onRecognized: () -> Void

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        @objc func didRecognize() {
            onRecognized()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let superview, let coordinator else { return }
            if installedSuperview === superview, recognizer != nil {
                return
            }
            removeRecognizer()
            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didRecognize)
            )
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            superview.addGestureRecognizer(recognizer)
            installedSuperview = superview
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedSuperview = nil
        }
    }
}

/// UIKit pinch recognizer used in addition to the SwiftUI timeline gestures.
/// `ScrollView` can win the SwiftUI gesture arena on a physical device before
/// `MagnifyGesture` receives a sample. Installing the recognizer on the same
/// host view and allowing simultaneous recognition keeps pinch available over
/// the whole gantt surface without disabling vertical scrolling or row taps.
struct TwoFingerPinchAttachment: UIViewRepresentable {
    let onChanged: (_ scale: CGFloat, _ anchor: CGFloat) -> Void
    let onEnded: (_ scale: CGFloat, _ anchor: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        uiView.installRecognizerIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (_ scale: CGFloat, _ anchor: CGFloat) -> Void
        var onEnded: (_ scale: CGFloat, _ anchor: CGFloat) -> Void

        init(
            onChanged: @escaping (_ scale: CGFloat, _ anchor: CGFloat) -> Void,
            onEnded: @escaping (_ scale: CGFloat, _ anchor: CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func didChange(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let width = max(view.bounds.width, 1)
            let location = recognizer.location(in: view)
            let anchor = min(1, max(0, location.x / width))
            let scale = max(0.01, recognizer.scale)
            switch recognizer.state {
            case .began, .changed:
                onChanged(scale, anchor)
            case .ended, .cancelled, .failed:
                onEnded(scale, anchor)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UIPinchGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let superview, let coordinator else { return }
            if installedSuperview === superview, recognizer != nil {
                return
            }
            removeRecognizer()
            let recognizer = UIPinchGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didChange(_:))
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = coordinator
            superview.addGestureRecognizer(recognizer)
            installedSuperview = superview
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedSuperview = nil
        }
    }
}

struct ScheduleView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneHour
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()
    // Photo clustering sorts the entire photo library. Keep that work out of
    // the playhead callback, which can arrive at 20 Hz while scrubbing.
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    // Keep the playhead lookup on pre-filtered collections. Repeating-goal
    // expansion can make snapshot.plans large, and rebuilding those filters
    // on every 20 Hz callback needlessly competes with gesture rendering.
    @State private var selectionIndexCache = TimelineSelectionIndexCache()
    @State private var weatherContextCache = TimelineWeatherContextCache()
    @State private var showsAirQualityDetails = false
    @State private var detailPanelHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let defaultPanelHeight = geometry.size.height * 0.5
            let resolvedPanelHeight = detailPanelHeight > 0
                ? min(detailPanelHeight, geometry.size.height)
                : defaultPanelHeight
            VStack(spacing: 0) {
                VStack(spacing: 0) {
            DraftTopBar(
                title: headerTitle,
                trailing: headerTrailing,
                selectedScale: model.selectedScale,
                onScaleChange: selectScaleFromTopBar,
                dayZoom: dayZoom,
                onDayZoomChange: { dayZoom = $0 },
                onTitleTap: { model.returnToNow() },
                onPrevious: { model.shiftSelectedDate(by: -1) },
                onNext: { model.shiftSelectedDate(by: 1) },
                onTrailingTap: closestWeather?.airQuality == nil
                    ? nil
                    : { showsAirQualityDetails = true },
                trailingAccessibilityLabel: "현재 날씨와 미세먼지 상세 보기",
                isPreviousEnabled: model.canShiftToPreviousPeriod,
                isNextEnabled: model.canShiftToNextPeriod
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            if let session = model.activeTrackingSession {
                liveTrackingBanner(session)
            }
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                dayZoom: $dayZoom,
                editingPlanID: $editingPlanID,
                onPlayheadMove: { date in
                    requestPlayheadDetailUpdate(at: date)
                },
                onSelection: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onFocus: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onPhotoSelection: { cluster in
                    playheadDetailGate.cancel()
                    editingPlanID = nil
                    mapPlayheadDate = nil
                    selectedPhotoCluster = cluster
                    selectedTimelineItem = TimelineSelection(
                        title: "사진",
                        span: cluster.detailSpan,
                        planID: nil,
                        recordNodeID: "automatic.photo.\(cluster.id)",
                        isRoute: false,
                        categoryID: "photo",
                        categoryName: "사진"
                    )
                    detailSection = .photo
                }
            )
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPlanID = nil
                }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
            TimelineDetailPanel(
                model: model,
                selection: selectedTimelineItem,
                playheadDate: mapPlayheadDate,
                panelHeight: $detailPanelHeight,
                section: $detailSection,
                highlightedSection: selectedTimelineItem?.preferredDetailSection,
                selectedPhotoCluster: $selectedPhotoCluster,
                routeReadings: model.mergingLiveSensorReadings(
                    routeReadings,
                    in: routeReadingsSpan
                ),
                onActualDeleted: { actualID in
                    if selectedTimelineItem?.actualID == actualID {
                        selectedTimelineItem = nil
                    }
                }
            )
            .frame(height: resolvedPanelHeight, alignment: .top)
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            }
            .onAppear {
                if detailPanelHeight == 0 {
                    detailPanelHeight = defaultPanelHeight
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .task(id: routeReadingsSpan) {
            routeReadings = await model.sensorReadings(in: routeReadingsSpan)
        }
        .onChange(of: model.timelineRevision) { _, _ in
            refreshPlayheadDetailAfterTimelineReload()
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
        .sheet(isPresented: $showsAirQualityDetails) {
            if let weather = closestWeather,
               let airQuality = weather.airQuality {
                AirQualityDetailSheet(
                    weather: weather,
                    airQuality: airQuality
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func selectScaleFromTopBar(_ scale: TimeScale) {
        model.selectScale(scale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: scale)
    }

    private func liveTrackingBanner(_ session: TrackingSession) -> some View {
        let lastSample = model.latestSensorReading?.timestamp
        return HStack(spacing: 8) {
            Image(
                systemName: session.kind == .running
                    ? "figure.run"
                    : "figure.walk"
            )
            .font(.taption(size: 13, weight: .bold))
            .foregroundStyle(Color.tpTransitDark)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.trackingSessionWasRecovered
                        ? "\(session.kind.displayName) 기록을 이어가는 중"
                        : "\(session.kind.displayName) 기록 중"
                )
                .font(.taption(size: 9.5, weight: .bold))
                Text(
                    lastSample.map {
                        "마지막 위치 \(relativeAgeText($0)) · 경로 \(model.liveRouteState.readings.count)개"
                    } ?? "아직 첫 위치를 기다리는 중"
                )
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button("종료") {
                Task { await model.stopTracking() }
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(Color.tpTransitDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.tpTransit.opacity(0.22))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpTransitDark.opacity(0.18)).frame(height: 0.5)
        }
    }

    private func relativeAgeText(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "방금" }
        return "\(seconds / 60)분 전"
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        playheadDetailGate.submit(
            date,
            minimumInterval: playheadDetailInterval(for: model.selectedScale)
        ) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func refreshPlayheadDetailAfterTimelineReload() {
        // The board can render its first playhead before the async sensor/
        // calendar snapshot arrives. Re-run the same lookup once the data
        // revision changes, otherwise the panel remains in the empty state.
        let date = mapPlayheadDate
            ?? (selectedTimelineItem == nil ? model.selectedDate : nil)
        guard let date else { return }
        requestPlayheadDetailUpdate(at: date)
    }

    private func focusMapOnPlayhead(at date: Date) {
        guard let selection = timelineSelection(at: date) else {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
            // Keep the playhead date for map tracking, but do not invent a
            // focused goal/action when that instant has no timeline item.
            if selectedTimelineItem != nil {
                selectedTimelineItem = nil
            }
            if detailSection != .map {
                detailSection = .map
            }
            return
        }

        // A 20 Hz playhead tick usually remains inside the same item. Avoid
        // assigning an equal value back into @State, which would rebuild the
        // entire detail panel despite no visible selection change.
        if selectedTimelineItem != selection {
            selectedTimelineItem = selection
        }
        if selection.categoryID != "photo" {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
        }
    }

    private func timelineSelection(at date: Date) -> TimelineSelection? {
        selectionIndexCache.prepare(
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents,
            categories: model.snapshot.categories,
            actuals: model.snapshot.actuals
        )
        let playheadMatch = TimelinePlayheadSynchronizer.match(
            at: date,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            places: model.snapshot.places,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents,
            weather: model.snapshot.weather
        )

        if let cluster = photoCluster(at: date) {
            if selectedPhotoCluster?.id != cluster.id {
                selectedPhotoCluster = cluster
            }
            return TimelineSelection(
                title: "사진",
                span: cluster.detailSpan,
                planID: nil,
                recordNodeID: "automatic.photo.\(cluster.id)",
                isRoute: false,
                categoryID: "photo",
                categoryName: "사진"
            )
        }

        if let travel = selectionIndexCache.travel(containing: date) {
            return TimelineSelection(
                title: timelineTravelModeName(travel.mode),
                span: travel.span,
                planID: nil,
                travelID: travel.id,
                recordNodeID: "automatic.travel.\(travel.id.uuidString)",
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        }

        if let actual = playheadMatch.automaticActuals.sorted(by: {
            if $0.startedAt == $1.startedAt {
                return $0.span(asOf: max(Date.now, date)).duration
                    < $1.span(asOf: max(Date.now, date)).duration
            }
            return $0.startedAt < $1.startedAt
        }).first {
            let span = actual.span(asOf: max(Date.now, date))
            return TimelineSelection(
                title: isMovementActual(actual)
                    ? movementActualTitle(actual)
                    : actual.title,
                span: span,
                planID: actual.routineID ?? actual.planID,
                actualID: actual.id,
                recordNodeID: "automatic.actual.\(actual.id.uuidString)",
                isRoute: false,
                categoryID: actual.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: actual.categoryID
                )
            )
        }

        if let weather = timelineWeather(at: date, in: model.snapshot.weather) {
            return timelineWeatherSelection(weather)
        }

        // Generated repeat segments are rendered as concrete timeline blocks,
        // but they are not root action items. Include them in playhead
        // selection so a 23:00–06:30 routine remains visible after midnight.
        if !TaptionProductScope.automaticLoggingOnly,
           let routine = selectionIndexCache.routinePlan(containing: date) {
            return TimelineSelection(
                title: routine.title,
                span: routine.span,
                planID: routine.id,
                isRoute: false,
                categoryID: routine.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: routine.categoryID
                )
            )
        }

        // A calendar item can cover an entire day. Prefer the automatic
        // record at the playhead so the detail panel follows the visible
        // sleep/activity block instead of showing the all-day event.
        if !TaptionProductScope.automaticLoggingOnly,
           let event = selectionIndexCache.eventPlan(containing: date) {
            return TimelineSelection(
                title: event.title,
                span: event.span,
                planID: event.id,
                isRoute: false,
                categoryID: "event",
                categoryName: "이벤트"
            )
        }

        if let calendarEvent = selectionIndexCache.calendarEvent(containing: date) {
            return TimelineSelection(
                title: calendarEvent.title,
                span: calendarEvent.span,
                planID: nil,
                recordNodeID: "automatic.calendar.\(calendarEvent.id)",
                isRoute: false,
                categoryID: "calendar",
                categoryName: "일정"
            )
        }

        if !TaptionProductScope.automaticLoggingOnly,
           let plan = selectionIndexCache.actionPlan(containing: date) {
            return TimelineSelection(
                title: plan.title,
                span: plan.span,
                planID: plan.id,
                isRoute: false,
                categoryID: plan.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: plan.categoryID
                )
            )
        }

        return nil
    }

    private func photoCluster(at date: Date) -> PhotoCluster? {
        let tolerance = photoPlayheadTolerance
        return photoClusterCache.nearest(
            timelineRevision: model.timelineRevision,
            photos: model.snapshot.photos,
            to: date,
            tolerance: tolerance
        )
    }

    private var photoPlayheadTolerance: TimeInterval {
        guard model.selectedScale == .day else { return 60 }
        return min(60, max(5, dayZoom.duration * 0.01))
    }

    private var headerTitle: String {
        ScheduleHeaderFormatter().playheadTitle(
            for: model.selectedDate,
            scale: model.selectedScale
        )
    }

    private var headerTrailing: String {
        switch model.selectedScale {
        case .day:
            if let weather = closestWeather {
                if let air = weather.airQuality {
                    "\(weather.temperatureCelsius.rounded().formatted())° · 미세 \(air.overallGrade.displayName) · \(weather.freshnessLabel)"
                } else {
                    "\(weather.temperatureCelsius.rounded().formatted())° · \(weather.condition) · \(weather.freshnessLabel)"
                }
            } else {
                ""
            }
        case .week:
            "W\(Calendar.autoupdatingCurrent.component(.weekOfYear, from: model.selectedDate))"
        case .month:
            "\(Calendar.autoupdatingCurrent.range(of: .day, in: .month, for: model.selectedDate)?.count ?? 30)일"
        case .year: "나의 한 해"
        }
    }

    private var visibleSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: model.selectedScale.timelineLevel,
            containing: model.selectedDate
        )
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var routeReadingsSpan: TimeSpan {
        if mapPlayheadDate != nil {
            return daySpan
        }
        return selectedTimelineItem?.span ?? daySpan
    }

    private var closestWeather: WeatherContext? {
        weatherContextCache.nearest(
            snapshotRevision: model.snapshotRevision,
            weather: model.snapshot.weather,
            inside: visibleSpan,
            to: model.selectedDate
        )
    }
}

private struct AirQualityDetailSheet: View {
    let weather: WeatherContext
    let airQuality: AirQualityContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: weather.symbolName)
                            .font(.taption(size: 25, weight: .semibold))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(weather.condition) · \(Int(weather.temperatureCelsius.rounded()))°")
                                .font(.taption(size: 18, weight: .bold))
                            Text("통합 미세먼지 \(airQuality.overallGrade.displayName)")
                                .font(.taption(size: 14, weight: .semibold))
                                .foregroundStyle(airQuality.overallGrade.displayColor)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: weather.isStale == true
                            ? "clock.arrow.circlepath"
                            : "checkmark.circle.fill")
                        Text(
                            weather.isStale == true
                                ? "마지막 확인 · \(weather.freshnessLabel)"
                                : "\(weather.freshnessLabel)"
                        )
                    }
                    .font(.taption(size: 11, weight: .semibold))
                    .foregroundStyle(
                        weather.isStale == true
                            ? Color.orange
                            : Color.tpSecondary
                    )

                    HStack(spacing: 10) {
                        pollutantCard(
                            title: "PM10",
                            value: airQuality.pm10MicrogramsPerCubicMeter,
                            grade: airQuality.pm10Grade
                        )
                        pollutantCard(
                            title: "PM2.5",
                            value: airQuality.pm25MicrogramsPerCubicMeter,
                            grade: airQuality.pm25Grade
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        detailRow(
                            "관측 시각",
                            airQuality.observedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        if let stationName = airQuality.stationName {
                            detailRow("측정소", stationName)
                        }
                        detailRow("제공원", airQuality.providerName)
                        if airQuality.isFallback {
                            Label(
                                "대체 자료",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.taption(size: 12, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                        }
                    }
                    .padding(14)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .padding(18)
            }
            .navigationTitle("날씨 · 미세먼지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private func pollutantCard(
        title: String,
        value: Double,
        grade: AirQualityGrade
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.taption(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            Text("\(Int(value.rounded())) μg/m³")
                .font(.taption(size: 18, weight: .bold))
            Text(grade.displayName)
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(grade.displayColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(Color.tpSecondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.taption(size: 13, weight: .medium))
    }
}

private extension AirQualityGrade {
    var displayColor: Color {
        switch self {
        case .good: Color(red: 0.20, green: 0.55, blue: 0.84)
        case .moderate: Color(red: 0.22, green: 0.62, blue: 0.34)
        case .bad: Color(red: 0.92, green: 0.55, blue: 0.12)
        case .veryBad: Color(red: 0.86, green: 0.20, blue: 0.20)
        }
    }
}

private func playheadFocusSpan(around date: Date) -> TimeSpan {
    // Relationship links are a supporting detail view, not the 20 Hz
    // playhead renderer. Quantize the graph's center to five-minute buckets so
    // scrubbing within a bucket reuses the same graph instead of rebuilding
    // all automatic/routine/action nodes on every delivered tick.
    let bucket = 5 * 60.0
    let bucketStart = floor(
        date.timeIntervalSinceReferenceDate / bucket
    ) * bucket
    let center = Date(timeIntervalSinceReferenceDate: bucketStart)
    return TimeSpan(
        start: center.addingTimeInterval(-15 * 60),
        end: center.addingTimeInterval(15 * 60)
    )
}

private func timelineTravelModeName(_ mode: TravelMode) -> String {
    switch mode {
    case .walking: "걷기"
    case .running: "달리기"
    case .cycling: "자전거"
    case .bus: "버스"
    case .subway: "지하철"
    case .taxi: "택시"
    case .car: "자동차"
    case .train: "기차"
    case .airplane: "비행기"
    case .ship: "배"
    }
}

enum TimelineRouteDisplayPolicy {
    static func segments(
        from travel: [TravelSegment],
        intersecting activeSpan: TimeSpan,
        at playheadDate: Date?,
        selectedTravelID: UUID? = nil
    ) -> [TravelSegment] {
        if let selectedTravelID {
            return travel.filter { $0.id == selectedTravelID }
        }
        if let playheadDate {
            return travel.filter { $0.span.contains(playheadDate) }
        }
        return travel.filter {
            $0.span.intersection(with: activeSpan) != nil
        }
    }

    static func allowsFallbackPath(
        at playheadDate: Date?,
        routeSegments: [TravelSegment]
    ) -> Bool {
        playheadDate == nil || !routeSegments.isEmpty
    }
}

private struct RecordRelationshipView: View {
    let graph: RecordRelationshipGraph

    private struct ConnectionChain: Identifiable {
        let id: String
        let titles: [String]
        let layers: [RecordLayer]
    }

    private let cardHeight: CGFloat = 27
    private let rowGap: CGFloat = 4
    private let columnGap: CGFloat = 12

    private var columns: [[RecordGraphNode]] {
        RecordLayer.allCases.map { layer in
            graph.nodes.filter { $0.layer == layer }
        }
    }

    /// Resolve the transitive chain once for the compact summary. Automatic
    /// evidence may point at either a routine or an action; hierarchy edges
    /// fill the missing hop so the user always sees the same structure.
    private var connectionChains: [ConnectionChain] {
        let nodesByID = Dictionary(
            graph.nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let outgoing = Dictionary(grouping: graph.edges, by: \.from)
        let incoming = Dictionary(grouping: graph.edges, by: \.to)
        var chains: [ConnectionChain] = []
        var seen = Set<String>()

        func add(_ nodes: [RecordGraphNode]) {
            guard nodes.count >= 2 else { return }
            let key = nodes.map(\.id).joined(separator: "|")
            guard seen.insert(key).inserted else { return }
            chains.append(
                ConnectionChain(
                    id: key,
                    titles: nodes.map(\.title),
                    layers: nodes.map(\.layer)
                )
            )
        }

        let routineActions = graph.edges.compactMap { edge -> (RecordGraphNode, RecordGraphNode)? in
            guard let routine = nodesByID[edge.from],
                  let action = nodesByID[edge.to],
                  routine.layer == .routine,
                  action.layer == .action else { return nil }
            return (routine, action)
        }
        for (routine, action) in routineActions {
            let automaticParents = incoming[action.id, default: []]
                .compactMap { nodesByID[$0.from] }
                .filter { $0.layer == .automatic }
            if automaticParents.isEmpty {
                add([routine, action])
            } else {
                for automatic in automaticParents {
                    add([automatic, routine, action])
                }
            }
        }

        for automatic in graph.nodes where automatic.layer == .automatic {
            let targets = outgoing[automatic.id, default: []]
                .compactMap { nodesByID[$0.to] }
            let routines = targets.filter { $0.layer == .routine }
            let actions = targets.filter { $0.layer == .action }
            for routine in routines {
                let children = outgoing[routine.id, default: []]
                    .compactMap { nodesByID[$0.to] }
                    .filter { $0.layer == .action }
                if children.isEmpty {
                    add([automatic, routine])
                } else {
                    for action in children {
                        add([automatic, routine, action])
                    }
                }
            }
            for action in actions {
                let parents = incoming[action.id, default: []]
                    .compactMap { nodesByID[$0.from] }
                    .filter { $0.layer == .routine }
                if parents.isEmpty {
                    add([automatic, action])
                } else {
                    for routine in parents {
                        add([automatic, routine, action])
                    }
                }
            }
        }
        return chains
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.taption(size: 10, weight: .bold))
                Text("연결 구조")
                    .font(.taption(size: 9.5, weight: .bold))
                Spacer(minLength: 4)
                Text("탭해서 루틴·액션 연결")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            if !connectionChains.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(connectionChains) { chain in
                        Label {
                            Text(chain.titles.enumerated().map { index, title in
                                let clean = chain.layers[index] == .routine
                                    ? displayNodeTitle(title)
                                    : title
                                return clean
                            }.joined(separator: "  →  "))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.taption(size: 8, weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Color.tpSleep.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let columnWidth = max(50, (width - columnGap * 2) / 3)
                let rowCount = max(1, columns.map(\.count).max() ?? 1)
                let contentHeight = CGFloat(rowCount) * (cardHeight + rowGap)

                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in graph.edges {
                            guard let from = point(
                                for: edge.from,
                                in: columns,
                                columnWidth: columnWidth,
                                outgoing: true
                            ), let to = point(
                                for: edge.to,
                                in: columns,
                                columnWidth: columnWidth,
                                outgoing: false
                            ) else { continue }
                            var path = Path()
                            path.move(to: from)
                            let midX = (from.x + to.x) / 2
                            path.addCurve(
                                to: to,
                                control1: CGPoint(x: midX, y: from.y),
                                control2: CGPoint(x: midX, y: to.y)
                            )
                            context.stroke(
                                path,
                                with: .color(Color.tpSecondary.opacity(0.28)),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                            )
                        }
                    }
                    .frame(width: width, height: contentHeight)
                    .allowsHitTesting(false)

                    HStack(alignment: .top, spacing: columnGap) {
                        ForEach(Array(RecordLayer.allCases.enumerated()), id: \.element) { index, layer in
                            VStack(alignment: .leading, spacing: rowGap) {
                                Text(layer.rawValue)
                                    .font(.taption(size: 7.5, weight: .bold))
                                    .foregroundStyle(layerColor(layer))
                                    .frame(height: 14, alignment: .leading)
                                ForEach(columns[index]) { node in
                                    Text(node.title)
                                        .font(.taption(size: 7.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                        .lineLimit(1)
                                        .padding(.horizontal, 5)
                                        .frame(width: columnWidth, height: cardHeight, alignment: .leading)
                                        .background(
                                            layerColor(layer).opacity(0.11),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                }
                            }
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                }
                .frame(height: contentHeight + 18, alignment: .top)
            }
            .frame(height: CGFloat(max(1, columns.map(\.count).max() ?? 1)) * (cardHeight + rowGap) + 18)
        }
        .padding(9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.5)
        }
    }

    private func point(
        for id: String,
        in columns: [[RecordGraphNode]],
        columnWidth: CGFloat,
        outgoing: Bool
    ) -> CGPoint? {
        for (column, nodes) in columns.enumerated() {
            guard let row = nodes.firstIndex(where: { $0.id == id }) else { continue }
            let x = CGFloat(column) * (columnWidth + columnGap)
                + (outgoing ? columnWidth : 0)
            let y = 14 + CGFloat(row) * (cardHeight + rowGap) + cardHeight / 2
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    private func layerColor(_ layer: RecordLayer) -> Color {
        switch layer {
        case .automatic: Color.tpPlaceDark
        case .routine: Color.tpSleepDark
        case .action: Color.tpInk
        }
    }

    private func displayNodeTitle(_ title: String) -> String {
        GoalRecordPolicy.displayTitle(title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TimelineDetailPanel: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let playheadDate: Date?
    @Binding var panelHeight: CGFloat
    @Binding var section: TimelineDetailSection
    let highlightedSection: TimelineDetailSection?
    @Binding var selectedPhotoCluster: PhotoCluster?
    let routeReadings: [SensorReading]
    let onActualDeleted: (UUID) -> Void
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoIndex = 0
    @State private var pendingActualDeletionID: UUID?
    @State private var showsGoalLinkSheet = false
    @State private var showsRecordLinkSheet = false
    @State private var showsActionLinkSheet = false
    @State private var actionPlanForRoutineLink: PlanRecord?
    @State private var lastMapFocusCoordinate: CLLocationCoordinate2D?
    // Mutating the gate itself does not invalidate the detail view, unlike a
    // rapidly changing @State timestamp on every live sensor callback.
    @State private var mapFitGate = TimelineMapFitGate()
    // The relationship graph is stable while the playhead remains inside the
    // same focused span. Cache it so a 20 Hz playhead update only reprojects
    // the visible detail cards instead of rebuilding every node and edge.
    @State private var relationshipGraphCache =
        TimelineRelationshipGraphCache()
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    // Route geometry is requested by several detail cards and by MapKit in
    // the same render pass. Cache the filtered segments and coordinate
    // polylines so a live playhead update does not rescan every reading for
    // each consumer.
    @State private var routePresentationCache =
        TimelineRoutePresentationCache()
    @State private var placeIndexCache = TimelinePlaceIndexCache()
    @State private var planIndexCache = TimelinePlanIndexCache()
    // The same filtered detail collections are consumed by both section
    // visibility and the card body. Reuse them for a playhead tick instead
    // of rescanning plans, actuals, places, and calendar events twice.
    @State private var detailDataCache = TimelineDetailDataCache()
    @State private var panelDragStartHeight: CGFloat?

    private var maximumPanelHeight: CGFloat {
        return max(
            detailPanelCollapsedHeight,
            UIScreen.main.bounds.height - 72
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            panelResizeHandle
            // Keep the selected item's icon visible while the playhead moves.
            // Empty intervals still have no header because activeSelection is
            // nil, so no stale routine title is invented.
            if activeSelection != nil {
                detailContextHeader
            }
            if playheadDate == nil,
               !TaptionProductScope.automaticLoggingOnly,
               let selection,
               selection.recordNodeID != nil,
               selection.actualID == nil,
               selection.categoryID != "location",
               selection.categoryID != "movement" {
                recordLinkControl(selection)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 9) {
                        ForEach(availableDetailSections) { item in
                            detailCard(for: item)
                                .id(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .background(Color.tpBackground)
                .onChange(of: section) { _, newSection in
                    withAnimation(.easeInOut(duration: 0.24)) {
                        proxy.scrollTo(newSection, anchor: .top)
                    }
                }
            }
        }
        .background(Color.tpBackground)
        .clipped()
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .onChange(of: selection) { _, _ in
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
            selectedPhotoIndex = 0
        }
        .onChange(of: playheadDate) { _, _ in
            // Playhead detail is delivered at 20 Hz, but MapKit does not
            // need a camera transaction for every delivered tick. Keep the
            // location marker responsive while limiting expensive region
            // updates to a 15 Hz presentation budget.
            fitMapToRoutes()
        }
        .onChange(of: routeReadingsSignature) { _, _ in
            fitMapToRoutes()
        }
        .onChange(of: model.latestSensorReading?.timestamp) { _, _ in
            // A fresh GPS fix is the source of truth for the idle map center.
            fitMapToRoutes()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            // Live tracking can update before the archived readings refresh.
            fitMapToRoutes()
        }
        .onChange(of: selectedPhotoCluster?.id) { _, _ in
            selectedPhotoIndex = 0
        }
        .task {
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
        }
        .confirmationDialog(
            "이 실제 기록을 삭제할까요?",
            isPresented: Binding(
                get: { pendingActualDeletionID != nil },
                set: { if !$0 { pendingActualDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("실제 기록 삭제", role: .destructive) {
                guard let actualID = pendingActualDeletionID else { return }
                pendingActualDeletionID = nil
                Task {
                    await model.deleteActual(actualID)
                    onActualDeleted(actualID)
                }
            }
            Button("취소", role: .cancel) {
                pendingActualDeletionID = nil
            }
        } message: {
            Text("이 기록만 삭제되며 연결된 계획은 그대로 유지됩니다.")
        }
        .sheet(isPresented: $showsGoalLinkSheet) {
            if let actual = selectedActual {
                GoalActualLinkSheet(model: model, actual: actual)
            }
        }
        .sheet(isPresented: $showsRecordLinkSheet) {
            if let selection,
               let sourceNodeID = selection.recordNodeID {
                RecordNodeLinkSheet(
                    model: model,
                    sourceNodeID: sourceNodeID,
                    sourceTitle: selection.title
                )
            }
        }
        .sheet(isPresented: $showsActionLinkSheet) {
            if let routine = focusedRoutineForDetail {
                GoalActionLinkSheet(model: model, goal: routine)
            }
        }
        .sheet(item: $actionPlanForRoutineLink) { action in
            RoutineActionLinkSheet(model: model, action: action)
        }
    }

    private var panelResizeHandle: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(Color.tpSecondary.opacity(0.45))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel("상세항목 패널 크기 조절")
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if panelDragStartHeight == nil {
                        panelDragStartHeight = panelHeight
                    }
                    let start = panelDragStartHeight ?? panelHeight
                    panelHeight = min(
                        maximumPanelHeight,
                        max(
                            detailPanelMinimumHeight,
                            start - value.translation.height
                        )
                    )
                }
                .onEnded { _ in
                    panelDragStartHeight = nil
                    withAnimation(.snappy(duration: 0.2)) {
                        if panelHeight < detailPanelCollapsedHeight - 36 {
                            panelHeight = detailPanelMinimumHeight
                        } else if panelHeight < detailPanelCollapsedHeight + 36 {
                            panelHeight = detailPanelCollapsedHeight
                        } else if panelHeight > maximumPanelHeight - 36 {
                            panelHeight = maximumPanelHeight
                        }
                    }
                }
        )
    }

    private var relationshipGraph: RecordRelationshipGraph? {
        // The graph belongs to a concrete selected record. Do not build a
        // graph for an empty playhead interval: that both violates the empty
        // detail-state contract and needlessly rebuilt all relationship nodes
        // on every 20 Hz scrub tick.
        guard relationshipFocusNodeID != nil else { return nil }
        let span = activeSelection?.span
            ?? playheadDate.map {
                TimeSpan(start: $0, end: $0.addingTimeInterval(1))
            }
            ?? daySpan
        let graph = relationshipGraphCache.value(
            for: .init(
                timelineRevision: model.timelineRevision,
                spanStart: span.start.timeIntervalSinceReferenceDate,
                spanEnd: span.end.timeIntervalSinceReferenceDate,
                focusNodeID: relationshipFocusNodeID
            )
        ) {
            RecordRelationshipEngine.make(
                inside: span,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals,
                calendarEvents: model.snapshot.calendarEvents,
                places: model.snapshot.places,
                travel: model.snapshot.travel,
                recordLinks: model.snapshot.recordLinks,
                focusNodeID: relationshipFocusNodeID
            )
        }
        return graph.hasConnections ? graph : nil
    }

    /// The detail graph is anchored to the item under the playhead. A
    /// repeated rule segment resolves to its root routine, so the panel shows
    /// the complete routine → action → automatic evidence chain instead of a
    /// detached one-off segment.
    private var relationshipFocusNodeID: String? {
        guard let selection = activeSelection else {
            guard let routine = focusedRoutineForDetail else { return nil }
            return "routine.\(routine.id.uuidString)"
        }
        if let nodeID = selection.recordNodeID {
            return nodeID
        }
        if let actualID = selection.actualID {
            return "automatic.actual.\(actualID.uuidString)"
        }
        if let travelID = selection.travelID {
            return "automatic.travel.\(travelID.uuidString)"
        }
        guard let planID = selection.planID,
              let plan = planIndexCache.plan(
                  id: planID,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) else { return nil }
        var current = plan
        var visited = Set<UUID>()
        while visited.insert(current.id).inserted {
            if GoalRecordPolicy.isGoal(current) {
                return "routine.\(current.id.uuidString)"
            }
            guard current.origin == .repeatRule,
                  let parentID = current.parentID,
                  let parent = planIndexCache.plan(
                      id: parentID,
                      timelineRevision: model.timelineRevision,
                      plans: model.snapshot.plans
                  ) else { break }
            current = parent
        }
        return current.origin == .repeatRule
            ? nil
            : "action.\(current.id.uuidString)"
    }

    private var availableDetailSections: [TimelineDetailSection] {
        let visible = TimelineDetailSection.defaultOrder.filter { section in
            if TaptionProductScope.automaticLoggingOnly {
                switch section {
                case .routine, .action, .event:
                    return false
                default:
                    break
                }
            }
            return switch section {
            case .schedule:
                hasScheduleContent
            case .location:
                hasLocationContent
            case .movement:
                hasMovementContent
            case .sleep:
                hasSleepContent
            case .activity:
                hasActivityContent
            case .appUsage:
                hasAppUsageContent
            case .weather:
                hasWeatherContent
            case .routine:
                hasRoutineContent
            case .action:
                hasActionContent
            case .photo:
                activePhotoCluster != nil
            case .event:
                hasEventContent
            case .map:
                hasMapContent
            }
        }
        let ordered = TimelineRowOrder.ordered(
            visible.filter { detailRowID(for: $0) != nil },
            id: { detailRowID(for: $0) ?? "" },
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let extras = visible.filter {
            detailRowID(for: $0) == nil && $0 != .map
        }
        var result = ordered
        if visible.contains(.map) {
            // 지도는 별도 행이 아니라 위치·이동의 상세 내용이다. 상단
            // 시간표에서 같은 행의 뒤에 삽입해 카드 순서를 유지한다.
            let anchorID = activeSelection?.isRoute == true
                ? "movement"
                : "location"
            let insertion = result.firstIndex {
                detailRowID(for: $0) == anchorID
            }.map { $0 + 1 } ?? result.count
            result.insert(.map, at: min(insertion, result.count))
        }
        return result + extras
    }

    private func detailRowID(
        for section: TimelineDetailSection
    ) -> String? {
        switch section {
        case .schedule: "calendar"
        case .location: "location"
        case .movement: "movement"
        case .sleep: "sleep"
        case .activity: "activity"
        case .appUsage: "appUsage"
        case .weather: "weather"
        case .photo: "photo"
        case .routine, .action, .event, .map: nil
        }
    }

    private func ensureVisibleDetailSection() {
        guard let first = availableDetailSections.first else { return }
        if !availableDetailSections.contains(section) {
            section = first
        }
    }

    private var detailContextHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            if playheadDetailSections.isEmpty {
                detailContextTitle
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(playheadDetailSections) { item in
                            Button {
                                section = item
                            } label: {
                                Label(item.rawValue, systemImage: item.systemImage)
                                    .font(.taption(size: 8.5, weight: .semibold))
                                    .foregroundStyle(
                                        section == item
                                            ? Color.white
                                            : Color.tpInk
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        section == item
                                            ? Color.tpInk
                                            : Color.white,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.rawValue) 상세 보기")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            if !playheadDetailSections.isEmpty {
                detailContextTitle
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 6)
        .background(Color(red: 0.94, green: 0.94, blue: 0.95))
    }

    private var detailContextTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: activeSelection?.preferredDetailSection.systemImage ?? "clock")
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: 24, height: 24)
                .background(
                    Color.white,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(activeSelection?.title ?? "하루 상세")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                Text(detailContextTimeLabel)
                    .font(.taption(size: 7.8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
    }

    private var playheadDetailSections: [TimelineDetailSection] {
        availableDetailSections.filter { $0 != .map }
    }

    private var detailContextTimeLabel: String {
        if let plan = selectedPlanForDetail,
           let repeatSummary = GoalRepeatRuleFormatter.summary(
               effectiveRepeatRules(for: plan)
           ) {
            return "반복 · \(repeatSummary)"
        }
        if let playheadDate {
            return playheadDate.formatted(date: .abbreviated, time: .shortened)
        }
        if let selection = activeSelection {
            let start = selection.span.start.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let end = selection.span.end.formatted(
                date: .omitted,
                time: .shortened
            )
            return "\(start)–\(end)"
        }
        return model.selectedDate.formatted(date: .complete, time: .omitted)
    }

    /// Generated repeat segments intentionally do not duplicate the rule
    /// payload. Resolve their parent here so the detail header still shows
    /// the configured clock time instead of the goal's date-only 00:00 span.
    private var selectedPlanForDetail: PlanRecord? {
        guard let selection = activeSelection,
              selection.actualID == nil,
              selection.travelID == nil,
              let planID = selection.planID else { return nil }
        return planIndexCache.plan(
            id: planID,
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans
        )
    }

    private var selectedRoutineForDetail: PlanRecord? {
        guard var plan = selectedPlanForDetail else { return nil }
        var visited = Set<UUID>()
        while visited.insert(plan.id).inserted {
            if GoalRecordPolicy.isGoal(plan) {
                return plan
            }
            guard let parentID = plan.parentID,
                  let parent = planIndexCache.plan(
                      id: parentID,
                      timelineRevision: model.timelineRevision,
                      plans: model.snapshot.plans
                  ) else {
                break
            }
            plan = parent
        }
        return nil
    }

    private var focusedRoutineForDetail: PlanRecord? {
        if playheadDate == nil {
            return selectedRoutineForDetail
        }
        guard let date = playheadDate else { return nil }
        let repeatParentIDs = Set(
            model.snapshot.plans
                .filter {
                    $0.origin == .repeatRule
                        && $0.span.contains(date)
                }
                .compactMap(\.parentID)
        )
        let goals = model.snapshot.plans.filter {
            GoalRecordPolicy.isGoal($0)
                && ($0.span.contains(date) || repeatParentIDs.contains($0.id))
        }
        let preferredCategories: [String]
        if activeSelection?.categoryID == "sleep"
            || !detailSleepPlans.isEmpty
            || !detailSleepActuals.isEmpty {
            preferredCategories = ["sleep"]
        } else if activeSelection?.categoryID == "activity"
            || !detailActivityPlans.isEmpty
            || !detailActivityActuals.isEmpty {
            preferredCategories = ["activity"]
        } else {
            preferredCategories = ["sleep", "activity"]
        }
        for categoryID in preferredCategories {
            if let goal = goals
                .filter({ $0.categoryID == categoryID })
                .min(by: focusedRoutineSort) {
                return goal
            }
        }
        return nil
    }

    private func focusedRoutineSort(
        _ lhs: PlanRecord,
        _ rhs: PlanRecord
    ) -> Bool {
        if lhs.span.duration == rhs.span.duration {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.span.duration < rhs.span.duration
    }

    /// A selected root routine is a valid detail target even when it has no
    /// child action yet. The routine card is the place where the user can
    /// inspect its repeat rule and add the first action.
    private var activeSelection: TimelineSelection? {
        guard let selection else { return nil }
        if TaptionProductScope.automaticLoggingOnly,
           selection.planID != nil,
           selection.actualID == nil,
           selection.travelID == nil {
            return nil
        }
        if TaptionProductScope.automaticLoggingOnly,
           let actualID = selection.actualID,
           let actual = model.snapshot.actuals.first(where: {
               $0.id == actualID
           }),
           !AutomaticRecordTimelineEngine.isImmutable(actual) {
            return nil
        }
        if let playheadDate, !selection.span.contains(playheadDate) {
            return nil
        }
        return selection
    }

    private func effectiveRepeatRules(
        for plan: PlanRecord
    ) -> [GoalRepeatRule]? {
        if plan.repeatRules?.isEmpty == false {
            return plan.repeatRules
        }
        guard plan.origin == .repeatRule,
              let parentID = plan.parentID,
              let parent = planIndexCache.plan(
                  id: parentID,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) else {
            return nil
        }
        return parent.repeatRules
    }

    @ViewBuilder
    private func detailCard(
        for item: TimelineDetailSection
    ) -> some View {
        let isFocused = activeSelection?.preferredDetailSection == item
            || (focusedRoutineForDetail != nil && item == .routine)
            || (activeSelection != nil && section == item)
        VStack(alignment: .leading, spacing: 7) {
            Group {
                switch item {
                case .schedule:
                    scheduleContent
                case .location:
                    locationContent
                case .movement:
                    movementContent
                case .sleep:
                    sleepContent
                case .activity:
                    activityContent
                case .appUsage:
                    appUsageContent
                case .weather:
                    weatherContent
                case .routine:
                    routineContent
                case .action:
                    actionContent
                case .photo:
                    photoContent
                case .event:
                    eventContent
                case .map:
                    routeContent
                }
            }
            if activeSelection?.preferredDetailSection == item {
                DetailMemoField(
                    model: model,
                    selection: activeSelection,
                    section: item
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            isFocused
                ? Color.tpInk.opacity(0.035)
                : Color.white,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isFocused
                        ? Color.tpInk.opacity(0.34)
                        : Color.tpLine.opacity(0.75),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.rawValue) 상세")
    }

    private var routeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    routeTitle,
                    systemImage: "map"
                )
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                Spacer()
                Text(isPlayheadLocationOnly ? "Apple 지도 위치" : "Apple 지도 경로")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            if !TaptionProductScope.automaticLoggingOnly {
                trackingControls
            }
            if let air = closestAirQuality {
                HStack(spacing: 6) {
                    Image(systemName: "aqi.medium")
                    Text("PM10 \(Int(air.pm10MicrogramsPerCubicMeter.rounded()))")
                    Text("PM2.5 \(Int(air.pm25MicrogramsPerCubicMeter.rounded()))")
                    Spacer(minLength: 4)
                    Text("\(air.stationName ?? air.providerName) · \(air.isFallback ? "대체값" : air.providerName)")
                        .lineLimit(1)
                }
                .font(.taption(size: 7.8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
            if !TaptionProductScope.automaticLoggingOnly,
               let travel = explicitlySelectedTravel {
                travelModeEditor(for: travel)
            }
            if !hasMapContent {
                Label("기록된 이동 경로가 없습니다", systemImage: "location.slash")
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                Map(position: $mapPosition, content: {
                    ForEach(routeLocationPins) { pin in
                        Marker(pin.title, systemImage: "mappin.circle.fill", coordinate: pin.coordinate)
                            .tint(pin.tint)
                    }

                    if let pin = playheadRoutePin {
                        Marker(pin.title, systemImage: "scope", coordinate: pin.coordinate)
                            .tint(Color.tpNow)
                    }

                    ForEach(routeSegments) { segment in
                        let coordinates = coordinates(for: segment)
                        if coordinates.count >= 2 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    routeColor(for: segment.mode).opacity(
                                        selectedSegmentIDs.contains(segment.id) ? 1 : 0.44
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: selectedSegmentIDs.contains(segment.id) ? 4 : 2.5,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                            )
                        }
                    }
                    if routeSegments.isEmpty,
                       displayedRouteCoordinates.count >= 2 {
                        MapPolyline(coordinates: displayedRouteCoordinates)
                            .stroke(
                                Color.tpTransitDark.opacity(0.72),
                                style: StrokeStyle(
                                    lineWidth: 3,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    } else if shouldDrawFallbackRoutePath {
                        MapPolyline(coordinates: fallbackRouteCoordinates)
                            .stroke(
                                Color.tpTransitDark.opacity(0.45),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                    }
                    if let selected = selectedSegment {
                        let coordinates = coordinates(for: selected)
                        if let first = coordinates.first {
                            Marker(
                                "출발",
                                systemImage: routeModeSystemImage(selected.mode),
                                coordinate: first
                            )
                                .tint(routeColor(for: selected.mode))
                        }
                        if coordinates.count >= 2, let last = coordinates.last {
                            Marker("도착", systemImage: "flag.fill", coordinate: last)
                                .tint(routeColor(for: selected.mode))
                        }
                    }
                })
                .mapStyle(.standard)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .frame(height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if displayedRouteCoordinates.count >= 2 {
                    HStack(spacing: 10) {
                        Label(
                            "GPS \(displayedRouteCoordinates.count)개",
                            systemImage: "location.fill"
                        )
                        Label(
                            distanceLabel(recordedRouteDistanceMeters),
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                        )
                        Spacer(minLength: 4)
                        Text("기록 경로")
                    }
                    .font(.taption(size: 7.8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                }
            }

            if isPlayheadLocationOnly {
                Text("이동 내용이 없어 현재 위치만 표시합니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }

            if !routeSegments.isEmpty &&
                routeSegments.flatMap(coordinates(for:)).count < 2 {
                Text("좌표 정밀도가 낮아 선분을 그릴 수 없어서 위치 마커만 표시 중입니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }
        }
    }

    private var trackingControls: some View {
        HStack(spacing: 6) {
            if let session = model.activeTrackingSession {
                Label(
                    "\(session.kind.displayName) 기록 중",
                    systemImage: session.kind == .running
                        ? "figure.run"
                        : "figure.walk"
                )
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                Spacer(minLength: 4)
                Button("종료") {
                    Task { await model.stopTracking() }
                }
                .font(.taption(size: 8.5, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await model.startTracking(.walking) }
                } label: {
                    Label("걷기 시작", systemImage: "figure.walk")
                }
                Button {
                    Task { await model.startTracking(.running) }
                } label: {
                    Label("달리기 시작", systemImage: "figure.run")
                }
                Spacer(minLength: 0)
            }
        }
        .font(.taption(size: 8.5, weight: .bold))
        .buttonStyle(.bordered)
    }

    private var closestAirQuality: AirQualityContext? {
        model.snapshot.weather
            .compactMap { weather in
                weather.airQuality.map { (weather.observedAt, $0) }
            }
            .min {
                abs($0.0.timeIntervalSince(playheadDate ?? .now))
                    < abs($1.0.timeIntervalSince(playheadDate ?? .now))
            }?.1
    }

    private var locationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("위치", systemImage: "mappin.and.ellipse")
            if detailPlaces.isEmpty {
                if let coordinate = currentLocationCoordinate {
                    HStack(spacing: 7) {
                        Image(systemName: "scope")
                            .foregroundStyle(Color.tpNow)
                        Text(
                            "현재 위치 · "
                                + String(format: "%.5f", coordinate.latitude)
                                + ", "
                                + String(format: "%.5f", coordinate.longitude)
                        )
                        .font(.taption(size: 9, weight: .semibold))
                    }
                }
            } else {
                ForEach(detailPlaces) { place in
                    HStack(spacing: 7) {
                        Image(systemName: "building.2")
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(Color.tpPlaceDark)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(placeTitle(place))
                                .font(.taption(size: 9, weight: .semibold))
                            Text(
                                "\(place.span.start.formatted(date: .omitted, time: .shortened))–\(place.span.end.formatted(date: .omitted, time: .shortened)) · \(confidenceLabel(place.confidence))"
                            )
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer(minLength: 4)
                        if let point = place.point {
                            Text("해발 \(Int(point.altitude.rounded()))m")
                                .font(.taption(size: 7.5, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                    }
                }
            }
            automaticNodeLinkControl(for: "location")
        }
    }

    private var movementContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("이동", systemImage: "figure.walk.motion")
            ForEach(detailTravel) { travel in
                HStack(spacing: 7) {
                    Image(systemName: routeModeSystemImage(travel.mode))
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(routeColor(for: travel.mode))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("알고리즘 결과 · \(timelineTravelModeName(travel.mode))")
                            .font(.taption(size: 9, weight: .semibold))
                        Text(
                            "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened)) · \(confidenceLabel(travel.confidence))"
                        )
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                        if let location = travelLocationLabel(travel) {
                            Text(location)
                                .font(.taption(size: 7.5, weight: .medium))
                                .foregroundStyle(Color.tpPlaceDark)
                        }
                        if !travel.evidence.isEmpty {
                            Text(travel.evidence.prefix(2).joined(separator: " · "))
                                .font(.taption(size: 7.2))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(distanceLabel(travel.distanceMeters))
                        .font(.taption(size: 8, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            ForEach(detailMovementActuals) { actual in
                HStack(spacing: 7) {
                    Image(
                        systemName: movementActualSymbol(actual)
                    )
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpHealthDark)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("알고리즘 결과 · \(movementActualTitle(actual))")
                            .font(.taption(size: 9, weight: .semibold))
                        Text(actualDetailSubtitle(actual))
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                        if !actual.evidence.isEmpty {
                            Text(actual.evidence.prefix(2).joined(separator: " · "))
                                .font(.taption(size: 7.2))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
            }
            automaticNodeLinkControl(for: "movement")
        }
    }

    @ViewBuilder
    private func automaticNodeLinkControl(for categoryID: String) -> some View {
        if !TaptionProductScope.automaticLoggingOnly,
           let selection = activeSelection,
           selection.categoryID == categoryID,
           selection.actualID == nil,
           selection.recordNodeID != nil {
            recordLinkControl(selection)
        }
    }

    private var sleepContent: some View {
        automaticRecordsContent(
            title: "수면",
            systemImage: "moon.zzz",
            plans: detailSleepPlans,
            actuals: detailSleepActuals,
            tint: Color.tpSleepDark
        )
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            automaticRecordsContent(
                title: "활동",
                systemImage: "figure.run",
                plans: detailActivityPlans,
                actuals: detailActivityActuals,
                tint: Color.tpHealthDark
            )
        }
    }

    private var appUsageContent: some View {
        automaticRecordsContent(
            title: "앱 사용",
            systemImage: "app.badge.clock",
            plans: [],
            actuals: detailData.appUsageActuals,
            tint: Color.tpProjectDark
        )
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("날씨", systemImage: "cloud.sun")
            ForEach(detailData.weather) { weather in
                HStack(spacing: 7) {
                    Image(systemName: weather.symbolName)
                        .font(.taption(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpWeatherDark)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            "\(weather.condition) · \(Int(weather.temperatureCelsius.rounded()))°"
                        )
                        .font(.taption(size: 9, weight: .semibold))
                        Text(weather.observedAt.formatted(
                            date: .omitted,
                            time: .shortened
                        ))
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                        Text(weatherMeasurementLocation(weather))
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer(minLength: 4)
                    if let air = weather.airQuality {
                        Text("미세 \(air.overallGrade.displayName)")
                            .font(.taption(size: 8, weight: .semibold))
                            .foregroundStyle(Color.tpWeatherDark)
                    }
                }
            }
        }
    }

    private func weatherMeasurementLocation(
        _ weather: WeatherContext
    ) -> String {
        if let placeName = weather.placeName,
           !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "측정 위치 · \(placeName)"
        }
        if let point = weather.point {
            return String(
                format: "측정 위치 · %.5f, %.5f",
                point.latitude,
                point.longitude
            )
        }
        return "측정 위치 · 위치 정보 없음"
    }

    private var routineContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeading("루틴", systemImage: "repeat.circle")
            if let routine = focusedRoutineForDetail {
                HStack(spacing: 8) {
                    Image(systemName: "repeat.circle.fill")
                        .font(.taption(size: 18, weight: .bold))
                        .foregroundStyle(Color.tpSleepDark)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routineDisplayTitle(routine))
                            .font(.taption(size: 13, weight: .bold))
                            .foregroundStyle(Color.tpInk)
                        Text(
                            "기간 · \(routine.span.start.formatted(date: .abbreviated, time: .omitted))–\(routine.span.end.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                    }
                }

                if let summary = GoalRepeatRuleFormatter.summary(
                    effectiveRepeatRules(for: routine)
                ) {
                    Label("반복 · \(summary)", systemImage: "calendar.badge.clock")
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tpSleepDark)
                }
                let descendants = (try? PlanHierarchy.descendants(
                    of: routine.id,
                    in: model.snapshot.plans
                )) ?? []
                let actions = descendants.filter { isManualActionPlan($0) }
                let linkedActuals = GoalActivityMatchingEngine.matches(
                    goal: routine,
                    plans: model.snapshot.plans,
                    actuals: model.snapshot.actuals
                )
                HStack(spacing: 8) {
                    Label("하위 액션 \(actions.count)개", systemImage: "checklist")
                    Label("연결 실적 \(linkedActuals.count)개", systemImage: "checkmark.circle")
                }
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)

                if !AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                    routine.categoryID
                ) {
                    Button {
                        showsActionLinkSheet = true
                    } label: {
                        Label("기존 액션아이템 연결", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if actions.isEmpty && linkedActuals.isEmpty {
                    Text(
                        AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                            routine.categoryID
                        )
                            ? "수면·활동 실적은 자동 기록 카드에서 루틴으로 연결합니다."
                            : "아직 연결된 액션이나 실적이 없습니다. 기존 액션을 연결하거나 새 하위 계획을 만들어 주세요."
                    )
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func automaticRecordsContent(
        title: String,
        systemImage: String,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading(title, systemImage: systemImage)
            ForEach(plans) { plan in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.72))
                        .frame(width: 5, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.title)
                            .font(.taption(size: 9, weight: .semibold))
                        Text("계획 · \(actionPlanTimeLabel(plan))")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            ForEach(actuals) { actual in
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            isMovementActual(actual)
                                ? movementActualTitle(actual)
                                : isSleepActual(actual)
                                    ? actual.title
                                    : restActualTitle(actual)
                        )
                            .font(.taption(size: 9, weight: .semibold))
                        Text(
                            actualDetailSubtitle(actual)
                        )
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            // Sleep and activity are both automatic evidence. Keep the same
            // explicit-link affordance for either type; only the currently
            // focused record gets a control so a list of records stays quiet.
            if !TaptionProductScope.automaticLoggingOnly,
               let actual = selectedActual,
               actuals.contains(where: { $0.id == actual.id }) {
                actualGoalLinkControl(actual)
            }
        }
    }

    private func actualDetailSubtitle(_ actual: ActualRecord) -> String {
        let span = "실제 · \(actual.startedAt.formatted(date: .omitted, time: .shortened))–\((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))"
        let source = actualSourceLabel(actual.source)
        guard let behavior = actual.behavior
            .flatMap({ WatchBehaviorKind(rawValue: $0) }) else {
            return "\(span) · \(source)"
        }
        return "\(span) · \(source) · \(behavior.title)"
    }

    private var actionContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeading("액션·메모", systemImage: "checklist.checked")
            if let actual = selectedActual {
                Text(actual.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(actual.startedAt.formatted(date: .omitted, time: .shortened)) → \((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                Text("실제 기록 · \(actualSourceLabel(actual.source))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                actualGoalLinkControl(actual)
                if AutomaticRecordTimelineEngine.isImmutable(actual) {
                    Label("자동 기록 · 수정 불가", systemImage: "lock.fill")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    Button(role: .destructive) {
                        pendingActualDeletionID = actual.id
                    } label: {
                        Label("실제 기록 삭제", systemImage: "trash")
                    }
                    .font(.taption(size: 9, weight: .bold))
                    .buttonStyle(.bordered)
                }
            } else if let plan = selectedManualActionPlan {
                Text(plan.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(plan.span.start.formatted(date: .omitted, time: .shortened)) → \(plan.span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                actionMemoPreview(planID: plan.id)
                routineLinkControl(for: plan)
            } else {
                let plans = activeActionPlans
                if plans.isEmpty {
                    Text("이날 등록된 액션아이템이 없습니다")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    ForEach(plans) { plan in
                        Button {
                            model.planEditorRequest = PlanEditorRequest(
                                id: plan.id
                            )
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(
                                    cornerRadius: plan.origin == .repeatRule
                                        ? 0
                                        : 4
                                )
                                .fill(Color.tpInk.opacity(0.12))
                                .frame(width: 5, height: 30)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title)
                                        .font(.taption(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                        .lineLimit(1)
                                    Text(actionPlanTimeLabel(plan))
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                let memoCount = model.memos(for: plan.id).count
                                if memoCount > 0 {
                                    Label("\(memoCount)", systemImage: "note.text")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.taption(size: 7, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Color.white.opacity(0.82),
                                in: RoundedRectangle(
                                    cornerRadius: 9,
                                    style: .continuous
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func routineLinkControl(for action: PlanRecord) -> some View {
        HStack(spacing: 6) {
            if let routine = routineForAction(action) {
                Label(
                    "연결된 루틴 · \(routineDisplayTitle(routine))",
                    systemImage: "repeat.circle.fill"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSleepDark)
                .lineLimit(1)
            } else {
                Label("연결된 루틴 없음", systemImage: "repeat.circle")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button(routineForAction(action) == nil ? "루틴 연결" : "루틴 변경") {
                actionPlanForRoutineLink = action
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func routineForAction(_ action: PlanRecord) -> PlanRecord? {
        var parentID = action.parentID
        var visited = Set<UUID>()
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = planIndexCache.plan(
                  id: id,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) {
            if GoalRecordPolicy.isGoal(parent) { return parent }
            parentID = parent.parentID
        }
        return nil
    }

    private func routineDisplayTitle(_ routine: PlanRecord) -> String {
        GoalRecordPolicy.displayTitle(routine.title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actualGoalLinkControl(_ actual: ActualRecord) -> some View {
        let routineOnly = AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
        return HStack(spacing: 6) {
            if let goal = goalForActual(actual) {
                Label(
                    "루틴 근거 · \(GoalRecordPolicy.displayTitle(goal.title).replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: ""))",
                    systemImage: "scope"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(PlanCategory(categoryID: goal.categoryID).darkColor)
                .lineLimit(1)
            } else {
                Label("연결된 루틴 없음", systemImage: "scope")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button {
                showsGoalLinkSheet = true
            } label: {
                Text(
                    goalForActual(actual) == nil
                        ? (routineOnly ? "루틴 연결" : "루틴·액션 연결")
                        : "연결 변경"
                )
                    .font(.taption(size: 8, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func recordLinkControl(_ selection: TimelineSelection) -> some View {
        HStack(spacing: 6) {
            Label("연결은 직접 선택", systemImage: "link.badge.plus")
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            Spacer(minLength: 4)
            Button("루틴·액션 연결") {
                showsRecordLinkSheet = true
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func goalForActual(_ actual: ActualRecord) -> PlanRecord? {
        if let routineID = actual.routineID,
           let routine = planIndexCache.plan(
               id: routineID,
               timelineRevision: model.timelineRevision,
               plans: model.snapshot.plans
           ),
           GoalRecordPolicy.isGoal(routine) {
            return routine
        }
        guard var planID = actual.planID else { return nil }
        var visited = Set<UUID>()
        while visited.insert(planID).inserted,
              let plan = planIndexCache.plan(
                  id: planID,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) {
            if GoalRecordPolicy.isGoal(plan) { return plan }
            guard let parentID = plan.parentID else { return nil }
            planID = parentID
        }
        return nil
    }

    private var activeActionPlans: [PlanRecord] {
        detailData.actionPlans
    }

    private let automaticDetailCategoryIDs: Set<String> = [
        "location",
        "movement",
        "sleep",
        "activity",
        "appUsage",
    ]

    private func isManualActionPlan(_ plan: PlanRecord) -> Bool {
        plan.categoryID != "event"
            && !automaticDetailCategoryIDs.contains(plan.categoryID)
            && !GoalRecordPolicy.isGoal(plan)
    }

    private var selectedManualActionPlan: PlanRecord? {
        detailData.selectedManualActionPlan
    }

    private var detailPlaces: [PlaceStay] {
        detailData.places
    }

    private var detailTravel: [TravelSegment] {
        detailData.travel
    }

    private var detailMovementActuals: [ActualRecord] {
        detailData.movementActuals
    }

    private var detailSleepPlans: [PlanRecord] {
        detailData.sleepPlans
    }

    private var detailActivityPlans: [PlanRecord] {
        detailData.activityPlans
    }

    private var detailSleepActuals: [ActualRecord] {
        detailData.sleepActuals
    }

    private var detailActivityActuals: [ActualRecord] {
        detailData.activityActuals
    }

    private var detailAppUsageActuals: [ActualRecord] {
        detailData.appUsageActuals
    }

    private var detailData: TimelineDetailDataCache.Value {
        let contentSpan = detailContentSpan
        let displaySpan = detailDisplaySpan
        let selection = activeSelection
        let cacheSpan = selection?.span ?? contentSpan
        let key = TimelineDetailDataCache.Key(
            timelineRevision: model.timelineRevision,
            contentStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            contentEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            displayStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            displayEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            playheadMinute: playheadDate.map {
                Int(floor($0.timeIntervalSinceReferenceDate / 60))
            },
            selectedPlanID: selection?.planID,
            selectedActualID: selection?.actualID,
            selectedTravelID: selection?.travelID,
            selectedRecordNodeID: selection?.recordNodeID,
            selectedCategoryID: selection?.categoryID
        )
        return detailDataCache.value(for: key) {
            let plans = TaptionProductScope.automaticLoggingOnly
                ? []
                : model.snapshot.plans
            let actuals = model.snapshot.actuals
            let automaticIDs = automaticDetailCategoryIDs
            // Automatic records are time-local. When the playhead is moving,
            // use its instant instead of the selected event's whole-day span;
            // an overnight repeat would otherwise show both adjacent days as
            // identical "23:00–06:30" rows.
            let focusedSpan = playheadDate.map {
                TimeSpan(
                    start: $0.addingTimeInterval(-1),
                    end: $0.addingTimeInterval(1)
                )
            } ?? contentSpan
            let playheadMatch = playheadDate.map { date in
                TimelinePlayheadSynchronizer.match(
                    at: date,
                    plans: plans,
                    actuals: actuals,
                    places: model.snapshot.places,
                    travel: model.snapshot.travel,
                    calendarEvents: model.snapshot.calendarEvents,
                    weather: model.snapshot.weather
                )
            }
            let matchedPlans = playheadMatch?.plans ?? plans
            let selectedPlan = selection?.planID.flatMap { planID in
                planIndexCache.plan(
                    id: planID,
                    timelineRevision: model.timelineRevision,
                    plans: plans
                )
            }
            let selectedManual = selectedPlan.flatMap { plan in
                isManualActionPlan(plan)
                    && plan.span.intersection(with: contentSpan) != nil
                    ? plan
                    : nil
            }
            let actionPlans: [PlanRecord]
            if let selectedManual {
                actionPlans = [selectedManual]
            } else {
                actionPlans = deduplicatedPlans(
                    matchedPlans
                        .filter { plan in
                            plan.status != .skipped
                                && plan.categoryID != "event"
                                && !automaticIDs.contains(plan.categoryID)
                                && plan.span.intersection(
                                    with: playheadDate == nil
                                        ? displaySpan
                                        : focusedSpan
                                ) != nil
                                && !GoalRecordPolicy.isGoal(plan)
                                && !(
                                    plan.parentID == nil
                                        && plan.repeatRules?.isEmpty == false
                                )
                        }
                        .sorted { $0.span.start < $1.span.start }
                )
            }
            let places = (playheadMatch?.places ?? model.snapshot.places
                .filter {
                    $0.span.intersection(with: focusedSpan) != nil
                })
                .sorted { $0.span.start < $1.span.start }
            let travel = (playheadMatch?.travel ?? model.snapshot.travel
                .filter {
                    $0.span.intersection(with: focusedSpan) != nil
                })
                .sorted { $0.span.start < $1.span.start }
            let sleepPlans = deduplicatedPlans(
                matchedPlans.filter {
                    $0.categoryID == "sleep"
                        && !GoalRecordPolicy.isGoal($0)
                        && $0.span.intersection(with: focusedSpan) != nil
                }
            )
            let activityPlans = deduplicatedPlans(
                matchedPlans.filter {
                    $0.categoryID == "activity"
                        && !GoalRecordPolicy.isGoal($0)
                        && $0.span.intersection(with: focusedSpan) != nil
                }
            )
            // The day timeline's automatic rows contain only HealthKit and
            // Apple Watch evidence. Timer/manual activity records belong to
            // the action layer and must not appear here when they are absent
            // from the visible activity row.
            let automaticActuals = playheadMatch?.automaticActuals
                ?? AutomaticRecordTimelineEngine.activities(
                    from: actuals,
                    inside: focusedSpan
                )
            let displayedAutomaticActuals = MovementDisplayEngine
                .visibleActuals(
                    automaticActuals,
                    travel: model.snapshot.travel,
                    asOf: .now
                )
            let sleepActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter { isSleepActual($0) }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let activityActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter {
                        !isSleepActual($0) && !isMovementActual($0)
                            && $0.categoryID != "appUsage"
                    }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let appUsageActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter { $0.categoryID == "appUsage" }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let movementActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter(isMovementActual)
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let weather = (playheadMatch?.weather ?? model.snapshot.weather
                .filter {
                    weatherTimelineSpan($0)
                        .intersection(with: focusedSpan) != nil
                })
                .sorted { $0.observedAt < $1.observedAt }
            let selectedActual = selection?.actualID.flatMap { actualID in
                (playheadMatch?.actuals ?? actuals).first { actual in
                    actual.id == actualID
                        && actual.span().intersection(with: contentSpan) != nil
                }
            }
            let eventPlans = matchedPlans
                .filter {
                    $0.span.intersection(with: displaySpan) != nil
                        && $0.categoryID == "event"
                        && $0.parentID == nil
                }
                .sorted { $0.span.start < $1.span.start }
            let calendarEvents = (playheadMatch?.calendarEvents
                ?? model.snapshot.calendarEvents.filter {
                    $0.span.intersection(with: displaySpan) != nil
                })
                .sorted { $0.span.start < $1.span.start }
            return TimelineDetailDataCache.Value(
                actionPlans: actionPlans,
                selectedManualActionPlan: selectedManual,
                places: places,
                travel: travel,
                movementActuals: movementActuals,
                sleepPlans: sleepPlans,
                activityPlans: activityPlans,
                sleepActuals: sleepActuals,
                activityActuals: activityActuals,
                appUsageActuals: appUsageActuals,
                weather: weather,
                selectedActual: selectedActual,
                eventPlans: eventPlans,
                calendarEvents: calendarEvents
            )
        }
    }

    private func deduplicatedPlans(
        _ plans: [PlanRecord]
    ) -> [PlanRecord] {
        var seen = Set<String>()
        return plans
            .sorted {
                if ($0.origin == .repeatRule) != ($1.origin == .repeatRule) {
                    return $0.origin != .repeatRule
                }
                return $0.span.start < $1.span.start
            }
            .filter { plan in
                let normalizedTitle = plan.title
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Repeat segments are generated projections. Their title can
                // differ between legacy and current stores, but an identical
                // slot is still one timeline segment.
                let key = [
                    plan.categoryID,
                    plan.origin == .repeatRule ? "repeat" : normalizedTitle,
                    String(Int(plan.span.start.timeIntervalSinceReferenceDate.rounded())),
                    String(Int(plan.span.end.timeIntervalSinceReferenceDate.rounded())),
                ].joined(separator: "|")
                return seen.insert(key).inserted
            }
    }

    private func deduplicatedActuals(
        _ actuals: [ActualRecord]
    ) -> [ActualRecord] {
        var seen = Set<String>()
        return actuals
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return actualSourcePriority($0.source)
                        > actualSourcePriority($1.source)
                }
                return $0.startedAt < $1.startedAt
            }
            .filter { actual in
                let end = actual.endedAt.map {
                    String(Int($0.timeIntervalSinceReferenceDate.rounded()))
                } ?? "open"
                let key = [
                    actual.categoryID,
                    actual.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    String(Int(actual.startedAt.timeIntervalSinceReferenceDate.rounded())),
                    end,
                ].joined(separator: "|")
                return seen.insert(key).inserted
            }
    }

    private func actualSourcePriority(_ source: ActualSource) -> Int {
        switch source {
        case .healthKit, .appleWatch, .motion, .media, .call, .appUsage: 3
        case .location: 2
        case .timer, .manual: 1
        case .calendar, .photo: 0
        }
    }

    private var detailContentSpan: TimeSpan {
        // Once the playhead is inside a concrete item, the detail payload is
        // stable for that item's full span. Using the raw playhead instant
        // here changed the cache key on every 20 Hz tick and rebuilt all plan,
        // actual, place and calendar filters while scrubbing.
        if let selection = activeSelection {
            return selection.span
        }
        if let playheadDate {
            return TimeSpan(
                start: playheadDate,
                end: playheadDate.addingTimeInterval(1)
            )
        }
        return activeSelection?.span ?? daySpan
    }

    private var detailDisplaySpan: TimeSpan {
        if playheadDate != nil || activeSelection != nil {
            return detailContentSpan
        }
        return daySpan
    }

    private var hasScheduleContent: Bool {
        !detailData.calendarEvents.isEmpty
    }

    private var hasLocationContent: Bool {
        !detailPlaces.isEmpty
            || (playheadDate == nil
                && activeSelection == nil
                && currentLocationCoordinate != nil)
    }

    private var hasMovementContent: Bool {
        !detailTravel.isEmpty || !detailMovementActuals.isEmpty
    }

    private var hasSleepContent: Bool {
        !detailSleepPlans.isEmpty || !detailSleepActuals.isEmpty
    }

    private var hasActivityContent: Bool {
        !detailActivityPlans.isEmpty || !detailActivityActuals.isEmpty
    }

    private var hasAppUsageContent: Bool {
        !detailAppUsageActuals.isEmpty
    }

    private var hasWeatherContent: Bool {
        !detailData.weather.isEmpty
    }

    private var hasRoutineContent: Bool {
        focusedRoutineForDetail != nil
    }

    private var hasActionContent: Bool {
        if let actual = selectedActual {
            return !isSleepActual(actual) && actual.categoryID != "activity"
        }
        return !activeActionPlans.isEmpty
    }

    private var hasEventContent: Bool {
        !detailData.eventPlans.isEmpty
    }

    private func isSleepActual(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "sleep"
            || actual.title.localizedCaseInsensitiveContains("수면")
            || actual.title.localizedCaseInsensitiveContains("sleep")
    }


    private func actionPlanTimeLabel(_ plan: PlanRecord) -> String {
        if let repeatSummary = GoalRepeatRuleFormatter.summary(
            effectiveRepeatRules(for: plan)
        ) {
            return repeatSummary
        }
        let start = plan.span.start.formatted(
            date: .omitted,
            time: .shortened
        )
        let end = plan.span.end.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(start)–\(end)"
    }

    private var selectedActual: ActualRecord? {
        detailData.selectedActual
    }

    private func actualSourceLabel(_ source: ActualSource) -> String {
        switch source {
        case .timer: "타이머"
        case .manual: "직접 기록"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch"
        case .motion: "iPhone 모션"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func confidenceLabel(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    private func placeTitle(_ place: PlaceStay) -> String {
        if let floor = place.floor {
            return place.displayName + " · " + String(floor) + "층"
        }
        return place.displayName
    }

    private func travelPlaceTitle(_ placeID: UUID?) -> String? {
        guard let placeID else { return nil }
        return (detailPlaces + model.snapshot.places)
            .first { $0.id == placeID }
            .map(placeTitle)
    }

    private func travelLocationLabel(_ travel: TravelSegment) -> String? {
        let from = travelPlaceTitle(travel.fromPlaceID)
        let to = travelPlaceTitle(travel.toPlaceID)
        switch (from, to) {
        case let (from?, to?): return from + " → " + to
        case let (from?, nil): return from + " → 위치 미확인"
        case let (nil, to?): return "위치 미확인 → " + to
        case (nil, nil): return nil
        }
    }

    private func distanceLabel(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1fkm", meters / 1_000)
        }
        return String(Int(meters.rounded())) + "m"
    }

    private func actionMemoPreview(planID: UUID) -> some View {
        let memos = model.memos(for: planID)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .font(.taption(size: 8.5, weight: .bold))
                Text("메모 \(memos.count)개")
                    .font(.taption(size: 9, weight: .bold))
                Spacer()
            }
            .foregroundStyle(Color.tpSecondary)

            if memos.isEmpty {
                Text("아직 메모가 없습니다. 결정, 아이디어, 막힘, 다음 할 일을 이 액션에 바로 붙여둘 수 있습니다.")
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(2)
            } else {
                ForEach(memos.prefix(2)) { memo in
                    Text("• \(memo.text)")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpInk.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
        }
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("이벤트", systemImage: "sparkles")
            let events = detailData.eventPlans
            if events.isEmpty {
                Text("이날 등록된 이벤트가 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(events) { event in
                    HStack {
                        Text(event.title).font(.taption(size: 9, weight: .semibold))
                        Spacer()
                        Text(event.span.start.formatted(date: .omitted, time: .shortened))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            Text("애플·구글 캘린더에서 가져온 내용은 ‘일정’ 카드에 표시됩니다.")
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private var photoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                detailHeading("사진", systemImage: "photo.on.rectangle")
                Spacer()
                if let cluster = activePhotoCluster {
                    Text("\(selectedPhotoIndex + 1) / \(cluster.photos.count)")
                        .font(.taption(size: 8, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }

            if let cluster = activePhotoCluster {
                let photos = cluster.photos.sorted { $0.capturedAt < $1.capturedAt }
                TabView(selection: $selectedPhotoIndex) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoClusterPage(
                            model: model,
                            photo: photo,
                            index: index,
                            totalCount: photos.count
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 220)
                .background(
                    Color.black,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(cluster.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ContentUnavailableView(
                    "이날 기록된 사진이 없습니다",
                    systemImage: "photo"
                )
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, minHeight: 84)
            }
        }
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("일정", systemImage: "calendar")
            let calendarEvents = detailData.calendarEvents
            if calendarEvents.isEmpty {
                Text("이날 등록된 일정이 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(calendarEvents) { event in
                    HStack(spacing: 7) {
                        Image(systemName: "calendar")
                            .font(.taption(size: 8, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.taption(size: 9, weight: .semibold))
                            Text(calendarSourceLabel(for: event))
                                .font(.taption(size: 7.5))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text(calendarEventDateTimeLabel(for: event))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = max(
            0,
            min(
                weekdaySymbols.count - 1,
                calendar.component(.weekday, from: date) - 1
            )
        )
        return "\(month)월 \(day)일 (\(weekdaySymbols[weekdayIndex]))"
    }

    private func calendarSourceLabel(for event: CalendarRecord) -> String {
        let source = event.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = event.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty, source != calendar {
            return "\(source) · \(calendar)"
        }
        return calendar.isEmpty ? "캘린더" : calendar
    }

    private func detailHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.taption(size: 10, weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(for: .day, containing: model.selectedDate)
    }

    private var activeRouteSpan: TimeSpan {
        if let playheadDate {
            if let selection = activeSelection,
               selection.isRoute,
               selection.span.contains(playheadDate) {
                return selection.span
            }
            return playheadFocusSpan(around: playheadDate)
        }
        return activeSelection?.span ?? daySpan
    }

    private var activePhotoSpan: TimeSpan {
        selectedPhotoCluster?.detailSpan ?? daySpan
    }

    private var activePhotoCluster: PhotoCluster? {
        if let playheadDate {
            guard activeSelection?.categoryID == "photo" else { return nil }
            guard let selectedPhotoCluster else { return nil }
            return selectedPhotoCluster.photos.contains(where: {
                abs($0.capturedAt.timeIntervalSince(playheadDate))
                    <= photoDetailTolerance
            }) ? selectedPhotoCluster : nil
        }
        if let selectedPhotoCluster {
            return selectedPhotoCluster
        }
        let photoSpan = activeSelection?.span ?? daySpan
        // The cached clusters are already chronological. Reuse that order
        // instead of filtering and sorting the full photo library whenever
        // the detail panel is redrawn.
        let photos = photoClusterCache.value(
            timelineRevision: model.timelineRevision,
            photos: model.snapshot.photos
        )
        .flatMap { cluster in
            cluster.photos.filter { photoSpan.contains($0.capturedAt) }
        }
        guard let representative = photos.first(where: \.isFavorite)
            ?? photos.first else {
            return nil
        }
        return PhotoCluster(
            id: "detail-\(representative.id)",
            representative: representative,
            photos: photos
        )
    }

    private var photoDetailTolerance: TimeInterval {
        60
    }

    private var routeTitle: String {
        if playheadDate != nil {
            return routeSegments.isEmpty && fallbackRouteCoordinates.count < 2
                ? "현재 위치"
                : "현재 이동 경로"
        }
        if activeSelection?.isRoute == true {
            return "선택된 이동 경로"
        }
        if activeSelection != nil {
            return "선택된 시간 경로"
        }
        return "오늘 이동 경로"
    }

    private var routeSegments: [TravelSegment] {
        routePresentationCache.segments(
            for: routePresentationCacheKey,
            span: activeRouteSpan,
            playheadDate: playheadDate,
            selectedTravelID: activeSelection?.travelID,
            travel: model.snapshot.travel
        ) {
            TimelineRouteDisplayPolicy.segments(
                from: model.snapshot.travel,
                intersecting: activeRouteSpan,
                at: playheadDate,
                selectedTravelID: activeSelection?.travelID
            )
        }
    }

    private var routePresentationCacheKey:
        TimelineRoutePresentationCache.Key {
        TimelineRoutePresentationCache.Key(
            timelineRevision: model.timelineRevision,
            readingsCount: routeReadings.count,
            firstReadingID: routeReadings.first?.id,
            lastReadingID: routeReadings.last?.id,
            firstReadingTimestamp: routeReadings.first?.timestamp,
            lastReadingTimestamp: routeReadings.last?.timestamp,
            liveRouteUpdatedAt: model.liveRouteState.lastUpdatedAt
        )
    }

    private var routeReadingsSignature: TimelineRouteReadingSignature {
        TimelineRouteReadingSignature(
            count: routeReadings.count,
            firstID: routeReadings.first?.id,
            lastID: routeReadings.last?.id,
            firstTimestamp: routeReadings.first?.timestamp,
            lastTimestamp: routeReadings.last?.timestamp
        )
    }

    private var explicitlySelectedTravel: TravelSegment? {
        guard playheadDate == nil, let travelID = activeSelection?.travelID else {
            return nil
        }
        return model.snapshot.travel.first { $0.id == travelID }
    }

    private var selectedSegmentIDs: Set<UUID> {
        guard let selection = activeSelection, selection.isRoute else {
            return Set(routeSegments.map(\.id))
        }
        return Set(routeSegments.filter {
            $0.span.intersection(with: selection.span) != nil
        }.map(\.id))
    }

    private var selectedSegment: TravelSegment? {
        guard let selection = activeSelection, selection.isRoute else { return nil }
        return routeSegments.first {
            $0.span.intersection(with: selection.span) != nil
        }
    }

    private struct RouteLocationPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String
        let tint: Color
    }

    private var routeLocationPins: [RouteLocationPin] {
        if playheadDate != nil && routeSegments.isEmpty {
            return []
        }

        var pins: [RouteLocationPin] = []
        var usedPlaceIDs = Set<UUID>()
        let values = selectedSegment == nil ? routeSegments : routeSegments.filter {
            selectedSegmentIDs.contains($0.id)
        }

        for segment in values {
            func appendIfValid(_ placeID: UUID?, segmentMode: TravelMode) {
                guard let placeID else { return }
                guard usedPlaceIDs.insert(placeID).inserted else { return }
                guard
                    let place = placeIndexCache.place(
                        id: placeID,
                        timelineRevision: model.timelineRevision,
                        places: model.snapshot.places
                    ),
                    let point = place.point,
                    isValidCoordinate(point) else { return }
                pins.append(
                    RouteLocationPin(
                        id: placeID.uuidString,
                        coordinate: CLLocationCoordinate2D(
                            latitude: point.latitude,
                            longitude: point.longitude
                        ),
                        title: place.displayName,
                        tint: routeColor(for: segmentMode)
                    )
                )
            }

            appendIfValid(segment.fromPlaceID, segmentMode: segment.mode)
            appendIfValid(segment.toPlaceID, segmentMode: segment.mode)
        }

        if pins.isEmpty {
            if !routeSegments.isEmpty {
                for segment in values {
                    let values = coordinates(for: segment)
                    if let first = values.first {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-start",
                                coordinate: first,
                                title: "\(routeModeName(segment.mode)) 시작",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                    if let last = values.last {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-end",
                                coordinate: last,
                                title: "\(routeModeName(segment.mode)) 종료",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                }
            } else if let first = fallbackRouteCoordinates.first {
                let last = fallbackRouteCoordinates.last ?? first
                pins.append(
                    RouteLocationPin(
                        id: "fallback-start",
                        coordinate: first,
                        title: "측정 시작",
                        tint: .tpTransitDark
                    )
                )
                if fallbackRouteCoordinates.count >= 2 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-end",
                            coordinate: last,
                            title: "측정 종료",
                            tint: .tpPlaceDark
                        )
                    )
                }
                if fallbackRouteCoordinates.count == 1 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-standby",
                            coordinate: CLLocationCoordinate2D(
                                latitude: first.latitude + 0.00002,
                                longitude: first.longitude + 0.00002
                            ),
                            title: "추정 이동 위치",
                            tint: .tpPlaceDark
                        )
                    )
                }
            }
        }

        // Outside timeline playback, the map is a live-location surface. Add
        // the current iPhone/Watch fix even when there is no travel segment so
        // the map remains available and has a concrete camera anchor.
        if playheadDate == nil,
           let coordinate = currentLocationCoordinate,
           !pins.contains(where: {
               CLLocation(
                   latitude: $0.coordinate.latitude,
                   longitude: $0.coordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: coordinate.latitude,
                       longitude: coordinate.longitude
                   )
               ) < 8
           }) {
            pins.append(
                RouteLocationPin(
                    id: "current-location",
                    coordinate: coordinate,
                    title: "현재 위치",
                    tint: Color.tpNow
                )
            )
        }
        return pins
    }

    private var playheadRoutePin: RouteLocationPin? {
        guard let coordinate = playheadFocusCoordinate else { return nil }
        return RouteLocationPin(
            id: "playhead-focus",
            coordinate: coordinate,
            title: "현재 위치",
            tint: .tpNow
        )
    }

    private var allowsFallbackRoutePath: Bool {
        TimelineRouteDisplayPolicy.allowsFallbackPath(
            at: playheadDate,
            routeSegments: routeSegments
        ) || fallbackRouteCoordinates.count >= 2
    }

    private var shouldDrawFallbackRoutePath: Bool {
        guard allowsFallbackRoutePath,
              fallbackRouteCoordinates.count >= 2 else {
            return false
        }
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        return routeSegments.isEmpty || segmentCoordinates.count < 2
    }

    private var isPlayheadLocationOnly: Bool {
        playheadDate != nil
            && routeSegments.isEmpty
            && fallbackRouteCoordinates.count < 2
            && playheadRoutePin != nil
    }

    private var hasMapContent: Bool {
        playheadRoutePin != nil
            || !routeLocationPins.isEmpty
            || !displayedRouteCoordinates.isEmpty
    }

    private var currentLocationCoordinate: CLLocationCoordinate2D? {
        let point = model.latestSensorReading?.point
            ?? model.liveRouteState.readings.last?.point
        guard let point, isValidCoordinate(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var playheadFocusCoordinate: CLLocationCoordinate2D? {
        guard let playheadDate else { return nil }

        // A GPS fix is the moving source of truth during playback. PlaceStay
        // is only a coarse fallback for gaps in the archived sensor stream.
        let nearestReadingPoint = nearestRouteReadingPoint(
            to: playheadDate,
            inside: activeRouteSpan
        )
        if let point = nearestReadingPoint {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        let place = placeIndexCache.containing(
            date: playheadDate,
            timelineRevision: model.timelineRevision,
            places: model.snapshot.places
        )
        if let place,
           let point = place.point,
           isValidCoordinate(point) {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        return routeSegments
            .filter { $0.span.contains(playheadDate) }
            .compactMap { coordinates(for: $0).first }
            .first
    }

    private func nearestRouteReadingPoint(
        to date: Date,
        inside span: TimeSpan
    ) -> GeoPoint? {
        guard !routeReadings.isEmpty else { return nil }

        // sensorReadings(in:) returns chronological data. Restrict the
        // binary search to the active span, then walk outward from the
        // insertion point. This avoids a full filter/min scan of up to 4,000
        // live GPS samples on every 20 Hz playhead update.
        var lower = 0
        var upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let firstInSpan = lower
        lower = firstInSpan
        upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp <= span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let endInSpan = lower
        guard firstInSpan < endInSpan else { return nil }

        lower = firstInSpan
        upper = endInSpan
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var left = lower - 1
        var right = lower
        var bestDistance = TimeInterval.infinity
        var bestPoint: GeoPoint?
        while left >= firstInSpan || right < endInSpan {
            let leftDistance = left >= firstInSpan
                ? abs(routeReadings[left].timestamp.timeIntervalSince(date))
                : .infinity
            let rightDistance = right < endInSpan
                ? abs(routeReadings[right].timestamp.timeIntervalSince(date))
                : .infinity
            if min(leftDistance, rightDistance) > bestDistance {
                break
            }
            if leftDistance <= rightDistance, left >= firstInSpan {
                if let point = routeReadings[left].point,
                   isValidCoordinate(point),
                   leftDistance < bestDistance {
                    bestDistance = leftDistance
                    bestPoint = point
                }
                left -= 1
            } else if right < endInSpan {
                if let point = routeReadings[right].point,
                   isValidCoordinate(point),
                   rightDistance < bestDistance {
                    bestDistance = rightDistance
                    bestPoint = point
                }
                right += 1
            }
        }
        return bestPoint
    }

    private var fallbackRouteCoordinates: [CLLocationCoordinate2D] {
        routePresentationCache.fallbackCoordinates(
            for: routePresentationCacheKey,
            span: activeRouteSpan
        ) {
            buildFallbackRouteCoordinates(in: activeRouteSpan)
        }
    }

    private func buildFallbackRouteCoordinates(
        in span: TimeSpan
    ) -> [CLLocationCoordinate2D] {
        // Archived readings and the live merge are chronological. Avoid a
        // full sort whenever a new GPS fix invalidates the route cache.
        let readings = routeReadings
            .filter { span.contains($0.timestamp) }
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let precise = readings.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
        }
        return simplifiedRouteCoordinates(
            precise.count >= 2 ? precise : readings
        )
    }

    private func simplifiedRouteCoordinates(
        _ points: [GeoPoint]
    ) -> [CLLocationCoordinate2D] {
        points.reduce(into: []) { result, point in
            let coordinate = CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
            guard let previous = result.last else {
                result.append(coordinate)
                return
            }
            if CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )) >= 3 {
                result.append(coordinate)
            }
        }
    }

    private var displayedRouteCoordinates: [CLLocationCoordinate2D] {
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        if segmentCoordinates.count >= 2 {
            return segmentCoordinates
        }
        guard allowsFallbackRoutePath else { return [] }
        return fallbackRouteCoordinates
    }

    private var recordedRouteDistanceMeters: Double {
        if !routeSegments.isEmpty {
            return routeSegments.reduce(0) { $0 + $1.distanceMeters }
        }
        return zip(
            displayedRouteCoordinates,
            displayedRouteCoordinates.dropFirst()
        ).reduce(0) { result, pair in
            result + CLLocation(
                latitude: pair.0.latitude,
                longitude: pair.0.longitude
            ).distance(from: CLLocation(
                latitude: pair.1.latitude,
                longitude: pair.1.longitude
            ))
        }
    }

    private func routeModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking:
            "걷기"
        case .running:
            "달리기"
        case .cycling:
            "자전거"
        case .bus:
            "버스"
        case .subway:
            "지하철"
        case .taxi:
            "택시"
        case .car:
            "자동차"
        case .train:
            "기차"
        case .airplane:
            "비행기"
        case .ship:
            "배"
        }
    }

    private func routeModeSystemImage(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus"
        case .subway: "tram"
        case .taxi: "car.side"
        case .car: "car"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry"
        }
    }

    private func travelModeEditor(for travel: TravelSegment) -> some View {
        HStack(spacing: 8) {
            Label(
                routeModeName(travel.mode),
                systemImage: routeModeSystemImage(travel.mode)
            )
            .font(.taption(size: 9, weight: .bold))
            .foregroundStyle(Color.tpInk)

            Text(
                "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened))"
            )
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)

            Spacer(minLength: 4)

            Menu {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Button {
                        model.confirmTravel(travel.id, mode: mode)
                    } label: {
                        Label(
                            routeModeName(mode),
                            systemImage: routeModeSystemImage(mode)
                        )
                    }
                }
            } label: {
                Label("이동수단 변경", systemImage: "pencil")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.tpInk, in: Capsule())
            }
            .accessibilityLabel("이동수단 변경")
            .accessibilityValue(routeModeName(travel.mode))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.tpLine, lineWidth: 0.7)
        }
    }

    private func isValidCoordinate(_ point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        return point.latitude >= -90 && point.latitude <= 90 &&
            point.longitude >= -180 && point.longitude <= 180 &&
            !(point.latitude == 0 && point.longitude == 0)
    }

    private func routeCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        var points: [GeoPoint] = []
        if let from = segment.fromPlaceID,
           let point = placeIndexCache.place(
               id: from,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }
        let readings = routeReadings
            .filter { segment.span.contains($0.timestamp) }
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let preferredReadings = includeImprecise
            ? readings
            : readings.filter {
                $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
            }

        if preferredReadings.count >= 2 || includeImprecise {
            points.append(contentsOf: preferredReadings)
        } else if let first = readings.first {
            points.append(first)
        }

        if let to = segment.toPlaceID,
           let point = placeIndexCache.place(
               id: to,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }

        return simplifiedRouteCoordinates(points)
    }

    private func coordinates(for segment: TravelSegment) -> [CLLocationCoordinate2D] {
        routePresentationCache.coordinates(
            for: routePresentationCacheKey,
            segmentID: segment.id,
            includeImprecise: false
        ) {
            buildCoordinates(for: segment, includeImprecise: false)
        }
    }

    private func buildCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        var values = routeCoordinates(
            for: segment,
            includeImprecise: includeImprecise
        )
        if !includeImprecise && (values.isEmpty || values.count == 1) {
            let fallback = routeCoordinates(for: segment, includeImprecise: true)
            if fallback.count >= 2 {
                return fallback
            }
            if fallback.count == 1 {
                values = fallback
            }
        }
        return values
    }

    private func routeColor(for mode: TravelMode) -> Color {
        switch mode {
        case .walking, .running: .tpHealthDark
        case .cycling: .tpTransitDark
        case .bus, .subway, .train: .tpProjectDark
        case .taxi, .car: .tpInk
        case .airplane, .ship: .tpPlaceDark
        }
    }

    private func fitMapToRoutes(force: Bool = false) {
        // Live sensor callbacks can arrive more often than MapKit needs. A
        // 30 Hz idle budget and a lighter 15 Hz playhead budget keep the
        // location-following map responsive without issuing duplicate region
        // transactions for every gesture sample; explicit selections still
        // bypass the throttle.
        let minimumInterval: TimeInterval = playheadDate == nil
            ? 1.0 / 30.0
            : 1.0 / 15.0
        guard mapFitGate.permits(
            force: force,
            minimumInterval: minimumInterval
        ) else {
            return
        }

        if playheadDate != nil, let focus = playheadFocusCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        if playheadDate == nil,
           activeSelection?.isRoute == true,
           displayedRouteCoordinates.count >= 2 {
            lastMapFocusCoordinate = nil
            fitMap(to: displayedRouteCoordinates)
            return
        }

        // When the timeline is idle without a selected route, the live
        // location remains the camera anchor.
        if playheadDate == nil, let focus = currentLocationCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        // If playback has a timestamp but no coordinate yet, retain the last
        // camera rather than jumping to an unrelated route midpoint.
        if playheadDate != nil {
            return
        }

        lastMapFocusCoordinate = nil

        let values = displayedRouteCoordinates
        guard !values.isEmpty else {
            mapPosition = .automatic
            return
        }
        fitMap(to: values)
    }

    private func fitMap(to values: [CLLocationCoordinate2D]) {
        let latitudes = values.map(\.latitude)
        let longitudes = values.map(\.longitude)
        mapPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (latitudes.min()! + latitudes.max()!) / 2,
                    longitude: (longitudes.min()! + longitudes.max()!) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.005, (latitudes.max()! - latitudes.min()!) * 1.45),
                    longitudeDelta: max(0.005, (longitudes.max()! - longitudes.min()!) * 1.45)
                )
            )
        )
    }
}

private struct RoutineActionLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let action: PlanRecord

    private var candidates: [PlanRecord] {
        GoalRecordPolicy.visibleGoals(in: model.snapshot.plans)
            .filter {
                $0.span.start <= action.span.start
                    && action.span.end <= $0.span.end
            }
            .sorted { lhs, rhs in
                let left = distanceScore(lhs)
                let right = distanceScore(rhs)
                if left == right { return lhs.span.start < rhs.span.start }
                return left < right
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "가까운 루틴이 없습니다",
                        systemImage: "repeat.circle",
                        description: Text("액션 시간을 포함하는 루틴을 먼저 만들어 주세요.")
                    )
                } else {
                    List(candidates) { routine in
                        Button {
                            Task {
                                await model.connectActionItem(
                                    action.id,
                                    toGoal: routine.id
                                )
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrentRoutine(routine)
                                    ? "checkmark.circle.fill"
                                    : "repeat.circle")
                                    .foregroundStyle(
                                        isCurrentRoutine(routine)
                                            ? Color.tpSleepDark
                                            : Color.tpSecondary
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routineDisplayTitle(routine))
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                        .lineLimit(1)
                                    Text(routineHint(routine))
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                if candidates.first?.id == routine.id {
                                    Text("가장 가까움")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpSleepDark)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("액션을 루틴에 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func distanceScore(_ routine: PlanRecord) -> TimeInterval {
        max(0, routine.span.duration - action.span.duration)
    }

    private func isCurrentRoutine(_ routine: PlanRecord) -> Bool {
        var parentID = action.parentID
        var visited = Set<UUID>()
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = model.snapshot.plans.first(where: { $0.id == id }) {
            if parent.id == routine.id { return true }
            parentID = parent.parentID
        }
        return false
    }

    private func routineDisplayTitle(_ routine: PlanRecord) -> String {
        GoalRecordPolicy.displayTitle(routine.title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func routineHint(_ routine: PlanRecord) -> String {
        let date = routine.span.start.formatted(date: .abbreviated, time: .omitted)
        return "액션 시간이 포함됨 · \(date)"
    }
}

private struct GoalActualLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let actual: ActualRecord
    @State private var candidateCache = GoalActualLinkCandidateCache()

    private var routinesOnly: Bool {
        AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
    }

    private var candidates: [GoalActualLinkCandidate] {
        candidateCache.values(
            actual: actual,
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans,
            routinesOnly: routinesOnly
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        routinesOnly ? "연결할 루틴이 없습니다" : "연결할 루틴·액션이 없습니다",
                        systemImage: "scope",
                        description: Text(
                            routinesOnly
                                ? "수면·활동 기록은 시간을 포함하는 루틴에만 연결할 수 있습니다."
                                : "먼저 루틴 탭에서 루틴을 만들어 주세요."
                        )
                    )
                } else {
                    List(candidates) { candidate in
                        let goal = candidate.plan
                        Button {
                            // The relationship is written to the in-memory
                            // snapshot immediately. Dismiss first so a slow
                            // disk/CloudKit/widget save never blocks the
                            // interaction surface.
                            dismiss()
                            Task {
                                await model.connectActualRecord(
                                    actual.id,
                                    toGoal: goal.id
                                )
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.isCurrent
                                    ? "checkmark.circle.fill"
                                    : "scope")
                                    .foregroundStyle(
                                        candidate.isCurrent
                                            ? PlanCategory(categoryID: goal.categoryID).darkColor
                                            : Color.tpSecondary
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(GoalRecordPolicy.isGoal(goal)
                                        ? GoalRecordPolicy.displayTitle(goal.title)
                                            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
                                        : goal.title)
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                    Text(candidate.hint)
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                if candidate.score >= 300 {
                                    Text(GoalRecordPolicy.isGoal(goal) ? "루틴" : "액션")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpHealthDark)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(
                routinesOnly ? "기록을 루틴에 연결" : "기록을 루틴·액션에 연결"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

private struct GoalActualLinkCandidate: Identifiable {
    let plan: PlanRecord
    let score: Int
    let isCurrent: Bool
    let hint: String

    var id: UUID { plan.id }
}

/// Builds activity-link candidates once per timeline revision. The previous
/// implementation rebuilt a parent dictionary and traversed every candidate's
/// descendants from inside the sort comparator and again for every row. With
/// repeat segments this became quadratic and made the sheet feel frozen.
@MainActor
private final class GoalActualLinkCandidateCache {
    private struct Key: Equatable {
        let timelineRevision: UInt64
        let actualID: UUID
        let routinesOnly: Bool
    }

    private var key: Key?
    private var cached: [GoalActualLinkCandidate] = []

    func values(
        actual: ActualRecord,
        timelineRevision: UInt64,
        plans: [PlanRecord],
        routinesOnly: Bool
    ) -> [GoalActualLinkCandidate] {
        let newKey = Key(
            timelineRevision: timelineRevision,
            actualID: actual.id,
            routinesOnly: routinesOnly
        )
        if key == newKey {
            return cached
        }

        let actualSpan = actual.span()
        let byID = Dictionary(
            plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let childrenByParent = Dictionary(
            grouping: plans.compactMap { plan in
                plan.parentID.map { ($0, plan) }
            },
            by: \.0
        )

        // Memoize the category set for each subtree. Every plan is visited at
        // most once, rather than rebuilding PlanHierarchy's index per sort
        // comparison.
        var categoriesBySubtree: [UUID: Set<String>] = [:]
        var visiting = Set<UUID>()
        func categories(in id: UUID) -> Set<String> {
            if let cached = categoriesBySubtree[id] {
                return cached
            }
            guard visiting.insert(id).inserted else {
                // Invalid cycles are rejected by the model, but returning the
                // node's own category keeps this UI cache total if a corrupt
                // snapshot is loaded.
                return byID[id].map { [$0.categoryID] } ?? []
            }
            var result = byID[id].map { Set([$0.categoryID]) } ?? []
            for child in childrenByParent[id, default: []] {
                result.formUnion(categories(in: child.1.id))
            }
            visiting.remove(id)
            categoriesBySubtree[id] = result
            return result
        }

        var currentIDs = Set<UUID>()
        if let routineID = actual.routineID {
            currentIDs.insert(routineID)
        }
        var visited = Set<UUID>()
        var parentID = actual.planID
        while let id = parentID,
              visited.insert(id).inserted,
              let plan = byID[id] {
            currentIDs.insert(plan.id)
            parentID = plan.parentID
        }

        let values = plans
            .filter {
                !$0.isFixed
                    && $0.status != .skipped
                    && $0.origin != .repeatRule
                    && $0.origin != .calendar
                    && (!routinesOnly || GoalRecordPolicy.isGoal($0))
            }
            .map { plan -> GoalActualLinkCandidate in
                let overlaps = plan.span.intersection(with: actualSpan) != nil
                let categoryMatches = categories(in: plan.id)
                    .contains(actual.categoryID)
                let isCurrent = currentIDs.contains(plan.id)
                let score: Int
                if isCurrent {
                    score = 1_000
                } else if categoryMatches && overlaps {
                    score = 300
                } else if overlaps {
                    score = 200
                } else if categoryMatches {
                    score = 100
                } else {
                    score = 0
                }
                let hint: String
                switch (categoryMatches, overlaps) {
                case (true, true): hint = "카테고리 · 시간 겹침"
                case (false, true): hint = "시간 겹침"
                case (true, false): hint = "같은 카테고리"
                case (false, false):
                    hint = plan.span.start.formatted(
                        date: .abbreviated,
                        time: .omitted
                    )
                }
                return GoalActualLinkCandidate(
                    plan: plan,
                    score: score,
                    isCurrent: isCurrent,
                    hint: hint
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.plan.span.start < rhs.plan.span.start
                }
                return lhs.score > rhs.score
            }

        key = newKey
        cached = values
        return values
    }
}

private struct RecordNodeLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let sourceNodeID: String
    let sourceTitle: String

    private var candidates: [PlanRecord] {
        model.snapshot.plans
            .filter {
                !$0.isFixed
                    && $0.status != .skipped
                    && $0.origin != .repeatRule
                    && $0.origin != .calendar
            }
            .sorted {
                if GoalRecordPolicy.isGoal($0) != GoalRecordPolicy.isGoal($1) {
                    return GoalRecordPolicy.isGoal($0)
                }
                return $0.span.start < $1.span.start
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "연결할 루틴 또는 액션이 없습니다",
                        systemImage: "link.badge.plus"
                    )
                } else {
                    List(candidates) { plan in
                        Button {
                            // Keep the detail card responsive while the
                            // relationship is persisted in the background.
                            dismiss()
                            Task {
                                await model.connectRecordNode(
                                    sourceNodeID,
                                    to: plan.id
                                )
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: GoalRecordPolicy.isGoal(plan)
                                    ? "repeat.circle"
                                    : "checklist")
                                    .foregroundStyle(
                                        GoalRecordPolicy.isGoal(plan)
                                            ? Color.tpSleepDark
                                            : Color.tpInk
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(GoalRecordPolicy.isGoal(plan)
                                        ? GoalRecordPolicy.displayTitle(plan.title)
                                        : plan.title)
                                        .font(.taption(size: 10, weight: .semibold))
                                    Text(
                                        "\(plan.span.start.formatted(date: .abbreviated, time: .shortened)) · "
                                            + (GoalRecordPolicy.isGoal(plan)
                                                ? "루틴"
                                                : "액션")
                                    )
                                    .font(.taption(size: 8))
                                    .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(sourceTitle) 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DetailMemoField: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let section: TimelineDetailSection
    @State private var text = ""
    @State private var editingMemoID: UUID?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !savedMemos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(savedMemos) { memo in
                        HStack(alignment: .top, spacing: 5) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memo.text)
                                    .font(.taption(size: 8.5))
                                    .foregroundStyle(Color.tpInk)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(memo.updatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.taption(size: 7))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                edit(memo)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.taption(size: 7, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("메모 편집")
                            Button {
                                delete(memo)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.taption(size: 7, weight: .bold))
                                    .foregroundStyle(Color.red)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("메모 삭제")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            Color.white.opacity(0.75),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                if memoCount > 0 {
                    Text("+\(memoCount)")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.tpProjectDark, in: Capsule())
                }
                TextField("이 항목에 메모 입력…", text: $text, axis: .vertical)
                    .font(.taption(size: 9))
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { save() }
                HStack(spacing: 3) {
                    memoAction("저장", systemImage: "checkmark", enabled: canSave) { save() }
                    memoAction("편집", systemImage: "pencil", enabled: latestMemo != nil) { edit() }
                    memoAction("삭제", systemImage: "trash", enabled: latestMemo != nil, destructive: true) { delete() }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
        }
        .onChange(of: selection) { _, _ in
            reset()
        }
        .accessibilityLabel("\(section.rawValue) 메모")
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var existingMemoPlanID: UUID? {
        if let planID = selection?.planID { return planID }
        if let actualID = selection?.actualID,
           let actual = model.snapshot.actuals.first(where: { $0.id == actualID }),
           let planID = actual.planID {
            return planID
        }
        guard let selection, let categoryID = selection.categoryID else { return nil }
        return model.snapshot.plans
            .filter {
                $0.categoryID == categoryID
                    && $0.title == "메모 - \(selection.categoryName ?? section.rawValue)"
                    && Calendar.autoupdatingCurrent.isDate($0.span.start, inSameDayAs: selection.span.start)
            }
            .sorted { $0.span.start > $1.span.start }
            .first?.id
    }

    private var savedMemos: [ActionMemo] {
        guard let selection else {
            return []
        }
        if let targetID = selection.memoTargetID {
            let targetMemos = model.memos(forTargetID: targetID)
            // Keep old plan-only notes visible after migrating a plan to the
            // stable target key, without duplicating newly keyed entries.
            guard targetID.hasPrefix("plan."), let planID = selection.planID else {
                return targetMemos
            }
            return (targetMemos + model.memos(for: planID))
                .reduce(into: [UUID: ActionMemo]()) { result, memo in
                    result[memo.id] = memo
                }
                .values
                .sorted { $0.createdAt < $1.createdAt }
        }
        guard let planID = existingMemoPlanID else { return [] }
        return model.memos(for: planID)
    }

    private var latestMemo: ActionMemo? {
        savedMemos.last
    }

    private var memoCount: Int {
        savedMemos.count
    }

    private func memoAction(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(
                    enabled
                        ? (destructive ? Color.red : Color.tpInk)
                        : Color.tpSecondary.opacity(0.35)
                )
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(enabled ? 0.8 : 0.35), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func edit(_ memo: ActionMemo) {
        editingMemoID = memo.id
        text = memo.text
        isFocused = true
    }

    private func edit() {
        guard let memo = latestMemo else { return }
        edit(memo)
    }

    private func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let editingMemoID {
            model.updateMemo(editingMemoID, text: clean, kind: .idea)
        } else if let targetID = selection?.memoTargetID,
                  let planID = memoTargetPlanID() {
            model.addMemo(
                text: clean,
                kind: .idea,
                toTargetID: targetID,
                planID: planID
            )
        } else if let planID = memoTargetPlanID() {
            model.addMemo(text: clean, kind: .idea, to: planID)
        }
        reset()
    }

    private func delete() {
        guard let memo = latestMemo else { return }
        delete(memo)
    }

    private func delete(_ memo: ActionMemo) {
        model.deleteMemo(memo.id)
        if editingMemoID == memo.id {
            reset()
        }
    }

    private func reset() {
        text = ""
        editingMemoID = nil
        isFocused = false
    }

    private func memoTargetPlanID() -> UUID? {
        if let planID = selection?.planID {
            return planID
        }
        if let actualID = selection?.actualID,
           let actual = model.snapshot.actuals.first(where: { $0.id == actualID }),
           let planID = actual.planID {
            return planID
        }
        guard let selection,
              let categoryID = selection.categoryID else {
            return nil
        }
        return model.memoPlan(
            forCategoryID: categoryID,
            categoryName: selection.categoryName ?? section.rawValue,
            near: selection.span.start
        ).id
    }
}

struct GroupGanttView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneHour
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    @State private var selectionIndexCache = TimelineSelectionIndexCache()
    @State private var detailPanelHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let defaultPanelHeight = geometry.size.height * 0.5
            let resolvedPanelHeight = detailPanelHeight > 0
                ? min(detailPanelHeight, geometry.size.height)
                : defaultPanelHeight
            VStack(spacing: 0) {
                VStack(spacing: 0) {
            DraftTopBar(
                title: selectedGroup?.title ?? "그룹 간트",
                trailing: selectedGroup.map(periodText) ?? "",
                selectedScale: model.selectedScale,
                onScaleChange: selectScaleFromTopBar,
                dayZoom: dayZoom,
                onDayZoomChange: { dayZoom = $0 },
                onBack: { model.closeCurrentGroup() }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                isGroup: true,
                dayZoom: $dayZoom,
                editingPlanID: $editingPlanID,
                onPlayheadMove: { date in
                    requestPlayheadDetailUpdate(at: date)
                },
                onSelection: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onFocus: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onPhotoSelection: { cluster in
                    playheadDetailGate.cancel()
                    editingPlanID = nil
                    mapPlayheadDate = nil
                    selectedPhotoCluster = cluster
                    selectedTimelineItem = TimelineSelection(
                        title: "사진",
                        span: cluster.detailSpan,
                        planID: nil,
                        recordNodeID: "automatic.photo.\(cluster.id)",
                        isRoute: false,
                        categoryID: "photo",
                        categoryName: "사진"
                    )
                    detailSection = .photo
                }
            )
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPlanID = nil
                }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
            TimelineDetailPanel(
                model: model,
                selection: selectedTimelineItem,
                playheadDate: mapPlayheadDate,
                panelHeight: $detailPanelHeight,
                section: $detailSection,
                highlightedSection: selectedTimelineItem?.preferredDetailSection,
                selectedPhotoCluster: $selectedPhotoCluster,
                routeReadings: model.mergingLiveSensorReadings(
                    routeReadings,
                    in: routeReadingsSpan
                ),
                onActualDeleted: { actualID in
                    if selectedTimelineItem?.actualID == actualID {
                        selectedTimelineItem = nil
                    }
                }
            )
            .frame(height: resolvedPanelHeight, alignment: .top)
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            }
            .onAppear {
                if detailPanelHeight == 0 {
                    detailPanelHeight = defaultPanelHeight
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .task(id: routeReadingsSpan) {
            routeReadings = await model.sensorReadings(in: routeReadingsSpan)
        }
        .onChange(of: model.timelineRevision) { _, _ in
            refreshPlayheadDetailAfterTimelineReload()
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
    }

    private func selectScaleFromTopBar(_ scale: TimeScale) {
        model.selectScale(scale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: scale)
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        playheadDetailGate.submit(
            date,
            minimumInterval: playheadDetailInterval(for: model.selectedScale)
        ) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func refreshPlayheadDetailAfterTimelineReload() {
        let date = mapPlayheadDate
            ?? (selectedTimelineItem == nil ? model.selectedDate : nil)
        guard let date else { return }
        requestPlayheadDetailUpdate(at: date)
    }

    private func focusMapOnPlayhead(at date: Date) {
        guard let selection = timelineSelection(at: date) else {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
            if selectedTimelineItem != nil {
                selectedTimelineItem = nil
            }
            if detailSection != .map {
                detailSection = .map
            }
            return
        }

        if selectedTimelineItem != selection {
            selectedTimelineItem = selection
        }
        if selection.categoryID != "photo" {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
        }
    }

    private func timelineSelection(at date: Date) -> TimelineSelection? {
        selectionIndexCache.prepare(
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents,
            categories: model.snapshot.categories,
            actuals: model.snapshot.actuals
        )
        let playheadMatch = TimelinePlayheadSynchronizer.match(
            at: date,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            places: model.snapshot.places,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents,
            weather: model.snapshot.weather
        )

        if let cluster = photoCluster(at: date) {
            if selectedPhotoCluster?.id != cluster.id {
                selectedPhotoCluster = cluster
            }
            return TimelineSelection(
                title: "사진",
                span: cluster.detailSpan,
                planID: nil,
                recordNodeID: "automatic.photo.\(cluster.id)",
                isRoute: false,
                categoryID: "photo",
                categoryName: "사진"
            )
        }

        if let travel = selectionIndexCache.travel(containing: date) {
            return TimelineSelection(
                title: timelineTravelModeName(travel.mode),
                span: travel.span,
                planID: nil,
                travelID: travel.id,
                recordNodeID: "automatic.travel.\(travel.id.uuidString)",
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        }

        if let actual = playheadMatch.automaticActuals.sorted(by: {
            if $0.startedAt == $1.startedAt {
                return $0.span(asOf: max(Date.now, date)).duration
                    < $1.span(asOf: max(Date.now, date)).duration
            }
            return $0.startedAt < $1.startedAt
        }).first {
            let span = actual.span(asOf: max(Date.now, date))
            return TimelineSelection(
                title: isMovementActual(actual)
                    ? movementActualTitle(actual)
                    : actual.title,
                span: span,
                planID: actual.routineID ?? actual.planID,
                actualID: actual.id,
                recordNodeID: "automatic.actual.\(actual.id.uuidString)",
                isRoute: false,
                categoryID: actual.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: actual.categoryID
                )
            )
        }

        if let weather = timelineWeather(at: date, in: model.snapshot.weather) {
            return timelineWeatherSelection(weather)
        }

        if !TaptionProductScope.automaticLoggingOnly,
           let routine = selectionIndexCache.routinePlan(containing: date) {
            return TimelineSelection(
                title: routine.title,
                span: routine.span,
                planID: routine.id,
                isRoute: false,
                categoryID: routine.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: routine.categoryID
                )
            )
        }

        // Keep the group timeline selection order identical to the main
        // timeline: automatic records win over all-day calendar blocks.
        if !TaptionProductScope.automaticLoggingOnly,
           let event = selectionIndexCache.eventPlan(containing: date) {
            return TimelineSelection(
                title: event.title,
                span: event.span,
                planID: event.id,
                isRoute: false,
                categoryID: "event",
                categoryName: "이벤트"
            )
        }

        if let calendarEvent = selectionIndexCache.calendarEvent(containing: date) {
            return TimelineSelection(
                title: calendarEvent.title,
                span: calendarEvent.span,
                planID: nil,
                recordNodeID: "automatic.calendar.\(calendarEvent.id)",
                isRoute: false,
                categoryID: "calendar",
                categoryName: "일정"
            )
        }

        if !TaptionProductScope.automaticLoggingOnly,
           let plan = selectionIndexCache.actionPlan(containing: date) {
            return TimelineSelection(
                title: plan.title,
                span: plan.span,
                planID: plan.id,
                isRoute: false,
                categoryID: plan.categoryID,
                categoryName: selectionIndexCache.categoryName(
                    for: plan.categoryID
                )
            )
        }

        return nil
    }

    private func photoCluster(at date: Date) -> PhotoCluster? {
        let tolerance = photoPlayheadTolerance
        return photoClusterCache.nearest(
            timelineRevision: model.timelineRevision,
            photos: model.snapshot.photos,
            to: date,
            tolerance: tolerance
        )
    }

    private var photoPlayheadTolerance: TimeInterval {
        guard model.selectedScale == .day else { return 60 }
        return min(60, max(5, dayZoom.duration * 0.01))
    }

    private var selectedGroup: PlanRecord? {
        guard let id = model.selectedGroupPlanID else { return nil }
        return model.snapshot.plans.first { $0.id == id }
    }

    private func periodText(_ plan: PlanRecord) -> String {
        "\(plan.span.start.formatted(.dateTime.month().day())) – \(plan.span.end.formatted(.dateTime.month().day()))"
    }

    private var selectedDaySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var routeReadingsSpan: TimeSpan {
        if mapPlayheadDate != nil {
            return selectedDaySpan
        }
        return selectedTimelineItem?.span ?? selectedDaySpan
    }
}

private struct TimelineBoardLayoutSnapshot {
    var rows: [TimelineRowModel]
    var axisMarkers: [TimelineAxisMarker]
    var photoClusters: [PhotoCluster]
    var summaryBuckets: [SummaryBucket]
    var summaryColors: [SummaryColor]
    var contentHeight: CGFloat
}

private struct TimelineBoardLayoutKey: Equatable {
    let timelineRevision: UInt64
    let scale: TimeScale
    let isGroup: Bool
    let selectedGroupPlanID: UUID?
    let spanStart: TimeInterval
    let spanEnd: TimeInterval
}

@MainActor
private final class TimelineBoardLayoutCache {
    private var key: TimelineBoardLayoutKey?
    private var snapshot: TimelineBoardLayoutSnapshot?

    func value(
        for key: TimelineBoardLayoutKey,
        build: () -> TimelineBoardLayoutSnapshot
    ) -> TimelineBoardLayoutSnapshot {
        if self.key == key, let snapshot {
            return snapshot
        }
        let snapshot = build()
        self.key = key
        self.snapshot = snapshot
        return snapshot
    }
}

private struct ContinuousMagnifyOrigin {
    let duration: TimeInterval
    let anchorDate: Date
    let anchor: Double
}

private struct TimelineBoard: View {
    @Bindable var model: AppModel
    let scale: TimeScale
    let storedPlans: [PlanRecord]
    var isGroup = false
    @Binding var dayZoom: TimelineZoomPreset
    @Binding var editingPlanID: UUID?
    var onPlayheadMove: ((Date) -> Void)?
    var onSelection: ((TimelineSelection) -> Void)?
    var onFocus: ((TimelineSelection) -> Void)?
    var onPhotoSelection: ((PhotoCluster) -> Void)?
    @State private var viewport = GanttViewport.full
    @State private var dragOrigin: GanttViewport?
    @State private var magnifyOrigin: GanttViewport?
    @State private var continuousCenterDate: Date = .now
    @State private var continuousDragOrigin: Date?
    @State private var continuousTimelineDuration: TimeInterval = 86_400
    @State private var preserveViewportAfterContinuousDrag = false
    // During a continuous-day drag, keep a slightly wider data window alive
    // so the rows are not rebuilt on every 240 Hz touch sample.  Blocks carry
    // their source dates and are reprojected against the moving display span
    // at render time; the wider window is rebuilt only when a drag starts or
    // ends.
    @State private var dragLayoutSpan: TimeSpan?
    @State private var zoomFeedbackSequence = 0
    @State private var continuousMagnifyOrigin: ContinuousMagnifyOrigin?
    @State private var selectedRowID: String?
    @State private var layoutCache = TimelineBoardLayoutCache()
    @State private var lastContinuousRenderUptime: TimeInterval = 0
    // Touch hardware can deliver 120/240 samples per second, while the
    // timeline only needs to invalidate at the display cadence.  Keeping a
    // separate gate for the non-continuous viewport gestures prevents week,
    // month, and year pans/pinches from rebuilding every row for every sample.
    @State private var lastViewportRenderUptime: TimeInterval = 0
    // Keep the ruler compact so the timeline retains the larger share of the
    // screen while still leaving room for labels and holiday names.
    private let axisHeight: CGFloat = 34

    var body: some View {
        // Resolve the moving span once per render pass.  Before this local
        // snapshot was introduced, every row and every gesture overlay asked
        // for `visibleSpan` independently, rebuilding Calendar intervals
        // several dozen times while a 240 Hz touch stream was being reduced
        // to the 60 Hz display budget.
        let displaySpan = visibleSpan
        let layoutSpan = dragLayoutSpan ?? displaySpan
        let layout = cachedLayoutSnapshot(in: layoutSpan)
        // Axis labels are cheap to derive and must follow the moving
        // playhead even while the wider drag window keeps row geometry
        // cached.
        let displayAxisMarkers = dragLayoutSpan == nil
            ? layout.axisMarkers
            : axisMarkers(in: displaySpan)
        let visibleDuration = displaySpan.duration * viewport.length
        GeometryReader { boardProxy in
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    GeometryReader { _ in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingPlanID = nil
                                }

                            // Rows can grow substantially once automatic
                            // location/activity history is populated. Lazy
                            // creation keeps off-screen rows out of the 240 Hz
                            // interaction path while fixed row heights still
                            // preserve the scrollable content size.
                            LazyVStack(spacing: 0) {
                                ForEach(layout.rows) { row in
                                    if row.id == "photo" {
                                        photoRow(layout.photoClusters)
                                            .draggable(row.id)
                                            .dropDestination(for: String.self) {
                                                sourceIDs, _ in
                                                guard let sourceID = sourceIDs.first
                                                else { return false }
                                                return finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                    } else {
                                        TimelineRow(
                                            row: row,
                                            isSelected: selectedRowID == row.id,
                                            editingPlanID: editingPlanID,
                                            visibleDuration: visibleDuration,
                                            viewport: viewport,
                                            displaySpan: displaySpan,
                                            scale: scale,
                                            useCachedBlockFractions:
                                                !isContinuousTimeline
                                                || dragLayoutSpan == nil,
                                            onBlockTap: handleTap,
                                            onBlockDoubleTap: focusOnBlock,
                                            onEdit: { editingPlanID = $0 },
                                            onMove: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.movePlan(planID, by: delta)
                                            },
                                            onResizeStart: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.resizePlan(
                                                    planID,
                                                    startDelta: delta
                                                )
                                            },
                                            onResizeEnd: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.resizePlan(
                                                    planID,
                                                    endDelta: delta
                                                )
                                            },
                                            onRowTap: { handleRowTap(row) },
                                            onDrop: { sourceID in
                                                finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                        )
                                    }
                                }

                                if scale != .day {
                                    summaryStrip(
                                        buckets: layout.summaryBuckets,
                                        colors: layout.summaryColors
                                    )
                                }
                            }

                            gridLines(markers: displayAxisMarkers)
                                .allowsHitTesting(false)

                            // The playhead is driven by `continuousCenterDate`
                            // during a drag and is always centered for the
                            // other resolutions. A minute-based TimelineView
                            // here only rebuilt this whole overlay for a date
                            // that was never read, so keep the line static
                            // until an actual playhead change arrives.
                            currentLine()
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: layout.contentHeight)
                }
                .scrollBounceBehavior(.basedOnSize)

                // Keep the time ruler below the timeline. It remains visible
                // while rows scroll, like a measuring scale in an editor.
                axis(markers: displayAxisMarkers)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            editingPlanID = nil
                        }
                    )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                viewportDragGesture(
                    width: max(
                        1,
                        boardProxy.size.width - scheduleLabelColumnWidth
                    )
                )
            )
            // Keep SwiftUI's recognizer as a second path for devices where a
            // UIScrollView consumes the UIKit pinch before the attached
            // recognizer receives it. Both paths share the same guarded
            // viewport state, so a single physical pinch is applied once.
            .simultaneousGesture(viewportMagnifyGesture)
            .background {
                TwoFingerPinchAttachment(
                    onChanged: { scale, anchor in
                        viewportMagnifyChanged(
                            factor: Double(scale),
                            anchor: Double(anchor)
                        )
                    },
                    onEnded: { scale, anchor in
                        viewportMagnifyEnded(
                            factor: Double(scale),
                            anchor: Double(anchor)
                        )
                    }
                )
            }
            .background {
                TwoFingerDoubleTapAttachment {
                    resetViewport(withFeedback: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
#if DEBUG
        .background(TimelineFrameBudgetProbeView())
#endif
        .background(Color.white)
        .onAppear {
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            onPlayheadMove?(continuousCenterDate)
        }
        .onChange(of: scale) { _, _ in
            preserveViewportAfterContinuousDrag = false
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            dragLayoutSpan = nil
            onPlayheadMove?(continuousCenterDate)
            resetViewport()
        }
        .onChange(of: model.selectedDate) { _, newDate in
            continuousCenterDate = newDate
            onPlayheadMove?(newDate)
            let preserveViewport = preserveViewportAfterContinuousDrag
            preserveViewportAfterContinuousDrag = false
            // A continuous drag changes the selected date, but it must not
            // change the viewport that a preceding pinch established. Keep
            // the current length as a fallback as well, because SwiftUI can
            // deliver this callback after the gesture-end transaction.
            let keepZoom = preserveViewport
                || !viewport.isFull
                || hasCustomContinuousDuration
            if continuousDragOrigin == nil {
                dragLayoutSpan = nil
                if !keepZoom {
                    continuousTimelineDuration = continuousDuration(around: newDate)
                    resetViewport()
                }
            }
        }
        .accessibilityHint(
            "간트 본문을 드래그해 이동하고 두 손가락으로 최대 1분 단위까지 확대합니다"
        )
        .accessibilityIdentifier("schedule.timeline.board")
        .accessibilityValue(currentResolutionLabel)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: zoomFeedbackSequence
        )
    }

    private func cachedLayoutSnapshot(
        in span: TimeSpan
    ) -> TimelineBoardLayoutSnapshot {
        let key = TimelineBoardLayoutKey(
            timelineRevision: model.timelineRevision,
            scale: scale,
            isGroup: isGroup,
            selectedGroupPlanID: model.selectedGroupPlanID,
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate
        )
        return layoutCache.value(for: key) {
            makeLayoutSnapshot(in: span)
        }
    }

    private func makeLayoutSnapshot(
        in span: TimeSpan
    ) -> TimelineBoardLayoutSnapshot {
        let index = TimelineBoardDataIndex(
            plans: storedPlans,
            categories: model.snapshot.categories
        )
        var rowModels = rows(in: span, index: index)
        let clusters = photoClusters(in: span)
        if scale == .day, !isGroup, !clusters.isEmpty {
            rowModels.append(
                TimelineRowModel(
                    title: "사진",
                    id: "photo",
                    dotColor: Color.tpPhotoDark,
                    isSystemAutomatic: true,
                    height: 65,
                    blocks: []
                )
            )
        }
        rowModels = TimelineRowOrder.ordered(
            rowModels,
            id: \.id,
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let buckets = summaryBuckets(in: span)
        let colors = summaryColors(for: buckets)
        // The photo lane is a real row now. Do not reserve the old footer
        // height as well, or the board grows an empty duplicate gap.
        let footerHeight: CGFloat = scale == .day ? 0 : 46
        return TimelineBoardLayoutSnapshot(
            rows: rowModels,
            axisMarkers: axisMarkers(in: span),
            photoClusters: clusters,
            summaryBuckets: buckets,
            summaryColors: colors,
            contentHeight: rowModels.reduce(0) { $0 + $1.height }
                + footerHeight
        )
    }

    private func axis(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            resolutionMenu
                .frame(width: scheduleLabelColumnWidth)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpLine.opacity(0.8))
                        .frame(height: 0.5)
                        .position(
                            x: proxy.size.width / 2,
                            y: 12
                        )

                    ForEach(Array(markers.enumerated()), id: \.element.id) {
                        index,
                        marker in
                        let x = markerX(marker, width: proxy.size.width)
                        let nextX: CGFloat = {
                            guard index + 1 < markers.count else { return x }
                            return markerX(
                                markers[index + 1],
                                width: proxy.size.width
                            )
                        }()

                        Rectangle()
                            .fill(
                                marker.isCurrent
                                    ? Color.tpNow
                                    : Color.tpSecondary.opacity(0.72)
                            )
                            .frame(
                                width: marker.isCurrent ? 1.5 : 1,
                                height: 11
                            )
                            .position(x: x, y: 6)

                        if nextX > x + 2 {
                            ForEach(1..<rulerMinorDivisionCount, id: \.self) {
                                division in
                                Rectangle()
                                    .fill(Color.tpLine.opacity(0.72))
                                    .frame(width: 0.5, height: 5)
                                    .position(
                                        x: x + (nextX - x) * CGFloat(division)
                                            / CGFloat(rulerMinorDivisionCount),
                                        y: 3
                                    )
                            }
                        }

                        Group {
                            if marker.date != nil, scale != .day {
                                Button {
                                    drillDown(from: marker)
                                } label: {
                                    axisMarkerLabel(marker)
                                }
                                .buttonStyle(.plain)
                            } else {
                                axisMarkerLabel(marker)
                            }
                        }
                        .accessibilityLabel(
                            marker.holidayName.map {
                                "\(marker.label), \($0)"
                            } ?? marker.label
                        )
                                .font(
                                    .taption(
                                    size: 8.5,
                                    weight: marker.isCurrent
                                        ? .bold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                marker.isCurrent
                                    ? Color.tpNow
                                    : Color.tpSecondary
                            )
                            .fixedSize()
                            .position(
                                x: x,
                                y: 24
                            )
                    }
                }
            }
            .clipped()
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: axisHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func axisMarkerLabel(
        _ marker: TimelineAxisMarker
    ) -> some View {
        VStack(spacing: 0) {
            Text(marker.label)
            if let holidayName = marker.holidayName {
                Text(holidayName)
                    .font(.taption(size: 6.5, weight: .semibold))
                    .foregroundStyle(Color.tpNow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
    }

    private func drillDown(from marker: TimelineAxisMarker) {
        guard let date = marker.date else { return }
        switch scale {
        case .week:
            model.selectedDate = date
            model.selectScale(.day)
            dayZoom = .oneHour
        case .month:
            model.selectedDate = date
            model.selectScale(.week)
            dayZoom = .oneWeek
        case .year:
            model.selectedDate = date
            model.selectScale(.month)
            dayZoom = .oneMonth
        case .day:
            return
        }
        onPlayheadMove?(date)
        zoomFeedbackSequence += 1
    }

    private var rulerMinorDivisionCount: Int {
        if isContinuousTimeline {
            return activeContinuousDuration <= 60 * 60 ? 5 : 4
        }
        return 2
    }

    private var resolutionMenu: some View {
        Menu {
            Section("화면 해상도") {
                ForEach(TimelineZoomPreset.allCases) { preset in
                    Button {
                        selectResolution(preset)
                    } label: {
                        HStack {
                            Text(preset.rawValue)
                            Spacer()
                            Text(preset.detail)
                                .foregroundStyle(.secondary)
                            if preset == currentResolutionPreset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if !viewport.isFull || hasCustomContinuousDuration {
                Section {
                    Button {
                        resetViewport(withFeedback: true)
                    } label: {
                        Label(
                            "현재 보기 전체로 맞춤",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentResolutionLabel)
                Image(systemName: "chevron.down")
                    .font(.taption(size: 6.5, weight: .bold))
            }
            .font(.taption(size: 8.5, weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("화면 해상도 \(currentResolutionLabel)")
        .accessibilityIdentifier("schedule.resolution.menu")
    }

    private var currentResolutionPreset: TimelineZoomPreset {
        TimelineZoomPreset.nearest(
            to: visibleSpan.duration * viewport.length
        )
    }

    private var currentResolutionLabel: String {
        TimelineZoomPreset.displayLabel(
            for: visibleSpan.duration * viewport.length
        )
    }

    private func selectResolution(_ preset: TimelineZoomPreset) {
        dayZoom = preset
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        continuousMagnifyOrigin = nil
        continuousDragOrigin = nil
        continuousTimelineDuration = preset.duration
        model.selectScale(preset.preferredScale)
        if preset.preferredScale == .day {
            continuousCenterDate = model.selectedDate
            onPlayheadMove?(continuousCenterDate)
        }
        zoomFeedbackSequence += 1
    }

    private func selectScaleForResolution(_ targetScale: TimeScale) {
        model.selectScale(targetScale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: targetScale)
        continuousTimelineDuration = continuousDuration(around: model.selectedDate)
    }

    private func rows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let resolved = resolvedRows(in: span, index: index)
        // Do not synthesize sample rows when the user has no records. Apart
        // from showing misleading plans, those placeholder blocks forced the
        // board to build and diff several extra rows on every viewport tick.
        return resolved
    }

    private func finishRowDrop(
        sourceID: String,
        targetID: String,
        rows: [TimelineRowModel]
    ) -> Bool {
        let ids = rows.map(\.id)
        guard let ordered = TimelineRowOrder.moved(
            ids,
            sourceID: sourceID,
            targetID: targetID,
            savedIDs: model.snapshot.settings.timelineRowOrder
        ) else {
            return false
        }
        model.setTimelineRowOrder(ordered)
        return true
    }

    private func resolvedRows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        if isGroup {
            guard let groupID = model.selectedGroupPlanID else { return [] }
            return rows(
                from: PlanHierarchy.children(of: groupID, in: storedPlans),
                includesCalendar: false,
                visibleSpan: span,
                index: index
            )
        }
        return rows(
            from: rootTimelinePlans,
            includesCalendar: true,
            visibleSpan: span,
            index: index
        )
    }

    private var rootTimelinePlans: [PlanRecord] {
        guard !TaptionProductScope.automaticLoggingOnly else { return [] }
        let repeatGoalIDs = Set(
            storedPlans
                .filter {
                    $0.parentID == nil
                        && ($0.repeatRules?.isEmpty == false)
                }
                .map(\.id)
        )
        .union(
            storedPlans
                .filter { $0.origin == .repeatRule }
                .compactMap(\.parentID)
        )
        return storedPlans.filter { plan in
            if plan.origin == .repeatRule {
                return true
            }
            if let _ = plan.parentID {
                return false
            }
            return !repeatGoalIDs.contains(plan.id)
        }
    }

    private func rows(
        from plans: [PlanRecord],
        includesCalendar: Bool,
        visibleSpan span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let visiblePlans = plans
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        let grouped = Dictionary(grouping: visiblePlans, by: \.categoryID)
        let now = Date.now
        let visibleActuals = AutomaticRecordTimelineEngine.visibleThroughNow(
            model.snapshot.actuals,
            asOf: now
        )
            .filter { $0.span(asOf: now).intersection(with: span) != nil }
            .sorted { $0.startedAt < $1.startedAt }
        let displayedVisibleActuals = MovementDisplayEngine.visibleActuals(
            visibleActuals,
            travel: model.snapshot.travel,
            asOf: now
        )
        let usesAutomaticDayRows = scale == .day && includesCalendar
        let automaticActuals = AutomaticRecordTimelineEngine.activities(
            from: displayedVisibleActuals,
            inside: span
        )
        let categoryVisibleActuals: [ActualRecord]
        if usesAutomaticDayRows && TaptionProductScope.automaticLoggingOnly {
            categoryVisibleActuals = []
        } else if usesAutomaticDayRows {
            categoryVisibleActuals = displayedVisibleActuals.filter {
                $0.source != .healthKit && $0.source != .appleWatch
            }
        } else {
            categoryVisibleActuals = displayedVisibleActuals
        }
        let actualsGrouped = Dictionary(
            grouping: categoryVisibleActuals,
            by: \.categoryID
        )
        var values: [TimelineRowModel] = []

        let events = model.snapshot.calendarEvents
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        if usesAutomaticDayRows {
            values.append(
                contentsOf: automaticDayRows(
                    events: events,
                    plansByCategory: grouped,
                    actuals: automaticActuals,
                    visibleSpan: span,
                    index: index
                )
            )
        } else if includesCalendar {
            if !events.isEmpty {
                let allocation = laneAllocation(events, span: \.span)
                values.append(
                    TimelineRowModel(
                        title: "일정",
                        dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                        isSystemAutomatic: true,
                        height: max(
                            60,
                            14 + CGFloat(allocation.count) * 28
                        ),
                        blocks: events.map { event in
                            timelineBlock(
                                title: event.title,
                                span: event.span,
                                top: 7 + CGFloat(
                                    allocation.lanes[event.id, default: 0]
                                ) * 28,
                                height: 22,
                                isFixed: true,
                                detailText: calendarDetailText(event)
                            )
                        }
                    )
                )
            }
        }
        if includesCalendar, !usesAutomaticDayRows {
            let weatherRow = automaticWeatherRow(visibleSpan: span)
            if !weatherRow.blocks.isEmpty {
                values.append(weatherRow)
            }
        }

        let orderedCategories = model.snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        for definition in orderedCategories {
            if usesAutomaticDayRows,
               GoalCategoryPolicy.systemSelectableCategoryIDs.contains(
                   definition.id
               ) {
                continue
            }
            let categoryPlans = grouped[definition.id, default: []]
            let categoryActuals = actualsGrouped[definition.id, default: []]
            if definition.isHidden,
               !GoalCategoryPolicy.systemSelectableCategoryIDs.contains(
                   definition.id
               ) {
                continue
            }
            guard !categoryPlans.isEmpty
                || !categoryActuals.isEmpty else {
                continue
            }
            let category = PlanCategory(categoryID: definition.id)
            let plansByPath = Dictionary(
                grouping: categoryPlans,
                by: PlanCategoryPathPresentation.key
            )
            let rootKey = PlanCategoryPathKey(
                categoryID: definition.id,
                middleName: nil,
                subName: nil
            )
            let rowKeys = Array(
                Set(plansByPath.keys)
                    .union(categoryActuals.isEmpty ? [] : [rootKey])
            )
            .sorted {
                PlanCategoryPathPresentation.isOrderedBefore(
                    $0,
                    $1,
                    categoryName: definition.name,
                    plansBeforeRoot: isGroup
                )
            }

            for key in rowKeys {
                let rowPlans = plansByPath[key, default: []]
                let rowActuals = key.isRoot ? categoryActuals : []
                let planAllocation = laneAllocation(
                    rowPlans,
                    span: \.span
                )
                let actualAllocation = laneAllocation(
                    rowActuals,
                    span: { $0.span() }
                )
                let planBlocks = rowPlans.map { plan in
                    timelineBlock(
                        plan: plan,
                        index: index,
                        top: 7 + CGFloat(
                            planAllocation.lanes[plan.id, default: 0]
                        ) * 28,
                        height: 22
                    )
                }
                let actualBlocks = rowActuals.map { actual in
                    timelineBlock(
                        actual: actual,
                        index: index,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(
                                actualAllocation.lanes[actual.id, default: 0]
                            ) * 16,
                        height: 12
                    )
                }
                let sensorBlocks = key.isRoot
                    ? sensorTimelineBlocks(
                        categoryID: definition.id,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16,
                        visibleSpan: span
                    )
                    : []
                let sensorLaneCount = sensorBlocks.isEmpty ? 0 : 1
                values.append(
                    TimelineRowModel(
                        title: PlanCategoryPathPresentation.title(
                            categoryName: definition.name,
                            key: key
                        ),
                        id: key.stableID,
                        category: category,
                        categoryID: definition.id,
                        dotColor: Color(hex: definition.darkHex),
                        fillColor: Color(hex: definition.lightHex),
                        actualColor: Color(hex: definition.actualHex),
                        height: max(
                            key.isRoot ? 52 : 64,
                            14
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(actualAllocation.count) * 16
                                + CGFloat(sensorLaneCount) * 22
                        ),
                        blocks: planBlocks + actualBlocks + sensorBlocks
                    )
                )
            }
        }

        let knownIDs = Set(orderedCategories.map(\.id))
        let unknownIDs = Set(grouped.keys)
            .union(actualsGrouped.keys)
            .subtracting(knownIDs)
        for categoryID in unknownIDs.sorted() {
            let categoryPlans = grouped[categoryID, default: []]
            let categoryActuals = actualsGrouped[categoryID, default: []]
            let planAllocation = laneAllocation(
                categoryPlans,
                span: \.span
            )
            let actualAllocation = laneAllocation(
                categoryActuals,
                span: { $0.span() }
            )
            values.append(
                TimelineRowModel(
                    title: categoryID,
                    category: PlanCategory(categoryID: categoryID),
                    categoryID: categoryID,
                    height: max(
                        60,
                        14
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16
                    ),
                    blocks: categoryPlans.map { plan in
                        timelineBlock(
                            plan: plan,
                            index: index,
                            top: 7 + CGFloat(
                                planAllocation.lanes[plan.id, default: 0]
                            ) * 28,
                            height: 22
                        )
                    } + categoryActuals.map { actual in
                        timelineBlock(
                            actual: actual,
                            index: index,
                            top: 7
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(
                                    actualAllocation.lanes[
                                        actual.id,
                                        default: 0
                                    ]
                                ) * 16,
                            height: 12
                        )
                    }
                )
            )
        }
        return values
    }

    private func automaticDayRows(
        events: [CalendarRecord],
        plansByCategory: [String: [PlanRecord]],
        actuals: [ActualRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        [
            automaticScheduleRow(events),
            automaticLocationRow(
                plans: plansByCategory["location", default: []],
                visibleSpan: visibleSpan,
                index: index
            ),
            automaticMovementRow(
                plans: plansByCategory["movement", default: []],
                actuals: actuals.filter(isMovementActual),
                visibleSpan: visibleSpan,
                index: index
            ),
            automaticSleepRow(
                plans: plansByCategory["sleep", default: []],
                actuals: actuals.filter(AutomaticRecordTimelineEngine.isSleep),
                index: index
            ),
            automaticActivityRow(
                plans: plansByCategory["activity", default: []],
                actuals: actuals.filter {
                    !AutomaticRecordTimelineEngine.isSleep($0)
                        && !isMovementActual($0)
                        && $0.categoryID != "appUsage"
                },
                index: index
            ),
            automaticAppUsageRow(
                actuals: actuals.filter { $0.categoryID == "appUsage" },
                index: index
            ),
            automaticWeatherRow(visibleSpan: visibleSpan),
        ]
    }

    private func automaticAppUsageRow(
        actuals: [ActualRecord],
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let values = actuals.filter { $0.startedAt <= .now }
        let allocation = laneAllocation(values, span: { $0.span() })
        let blocks = values.map { actual in
            timelineBlock(
                id: actual.id,
                title: actual.title,
                span: actual.span(),
                top: compactAutomaticTop(
                    allocation.lanes[actual.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                detailText: "자동 앱 사용 · (actualSourceName(actual.source))",
                categoryID: "appUsage",
                categoryName: "앱 사용"
            )
        }
        return TimelineRowModel(
            title: "앱 사용",
            id: "appUsage",
            dotColor: .tpProjectDark,
            systemImage: "app.badge.clock",
            fillColor: .tpProject,
            actualColor: .tpProjectDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    private func automaticWeatherRow(
        visibleSpan: TimeSpan
    ) -> TimelineRowModel {
        let now = Date.now
        let contexts = WeatherTimelineEngine.coalesced(model.snapshot.weather)
            .filter {
                $0.observedAt <= now
                    && weatherTimelineSpan($0)
                        .intersection(with: visibleSpan) != nil
            }
            .sorted { $0.observedAt < $1.observedAt }
        let allocation = laneAllocation(contexts) { context in
            automaticSpanThroughNow(
                weatherTimelineSpan(context),
                asOf: now
            ) ?? weatherTimelineSpan(context)
        }
        let blocks = contexts.map { context in
            let span = automaticSpanThroughNow(
                weatherTimelineSpan(context),
                asOf: now
            ) ?? weatherTimelineSpan(context)
            return timelineBlock(
                id: context.id,
                title: weatherTimelineTitle(context),
                span: span,
                top: compactAutomaticTop(
                    allocation.lanes[context.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                detailText: weatherTimelineDetail(context),
                categoryID: "weather",
                categoryName: "날씨"
            )
        }
        return TimelineRowModel(
            title: "날씨",
            id: "weather",
            dotColor: .tpWeatherDark,
            systemImage: contexts.first?.symbolName ?? "cloud.sun",
            fillColor: .tpWeather,
            actualColor: .tpWeatherDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    private func automaticScheduleRow(
        _ events: [CalendarRecord]
    ) -> TimelineRowModel {
        let allocation = laneAllocation(events, span: \.span)
        return TimelineRowModel(
            title: "일정",
            id: "calendar",
            categoryID: "calendar",
            dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: events.map { event in
                timelineBlock(
                    title: event.title,
                    span: event.span,
                    top: compactAutomaticTop(
                        allocation.lanes[event.id, default: 0]
                    ),
                    height: 14,
                    isFixed: true,
                    detailText: calendarDetailText(event),
                    categoryID: "calendar",
                    categoryName: "일정"
                )
            }
        )
    }

    private func automaticLocationRow(
        plans: [PlanRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let now = Date.now
        let visiblePlans = plans.filter { $0.span.start <= now }
        let visiblePlaces = model.snapshot.places
            .compactMap { place -> PlaceStay? in
                guard place.span.start <= now,
                      let clipped = place.span.intersection(
                          with: TimeSpan(start: .distantPast, end: now)
                      ) else { return nil }
                var value = place
                value.span = clipped
                return value
            }
            .filter { $0.span.intersection(with: visibleSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
        let planAllocation = laneAllocation(visiblePlans, span: \.span)
        let placeAllocation = laneAllocation(visiblePlaces, span: \.span)
        let offset = planAllocation.count
        let planBlocks = visiblePlans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        let placeBlocks = visiblePlaces.map { place in
            let title = place.floor.map {
                "\(place.displayName) · \($0)층"
            } ?? place.displayName
            let altitude = place.point.map {
                "해발 \(Int($0.altitude.rounded()))m"
                    + (
                        $0.verticalAccuracy >= 0
                            ? " · ±\(Int($0.verticalAccuracy.rounded()))m"
                            : ""
                    )
            }
            return timelineBlock(
                id: place.id,
                title: title,
                span: place.span,
                top: compactAutomaticTop(
                    offset
                        + placeAllocation.lanes[place.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText: [
                    "자동 위치",
                    confidenceName(place.confidence),
                    altitude,
                ]
                .compactMap { $0 }
                .joined(separator: " · "),
                categoryID: "location",
                categoryName: "위치"
            )
        }
        return TimelineRowModel(
            title: "위치",
            id: "location",
            category: .location,
            categoryID: "location",
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + placeAllocation.count
            ),
            blocks: planBlocks + placeBlocks
        )
    }

    private func automaticMovementRow(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let now = Date.now
        let visiblePlans = plans.filter { $0.span.start <= now }
        let visibleTravel = model.snapshot.travel
            .compactMap { travel -> TravelSegment? in
                guard travel.span.start <= now,
                      let clipped = travel.span.intersection(
                          with: TimeSpan(
                              start: .distantPast,
                              end: now
                          )
                      ) else { return nil }
                var value = travel
                value.span = clipped
                return value
            }
            .filter { $0.span.intersection(with: visibleSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
        let planAllocation = laneAllocation(visiblePlans, span: \.span)
        let travelAllocation = laneAllocation(visibleTravel, span: \.span)
        let actualAllocation = laneAllocation(actuals, span: { $0.span() })
        let offset = planAllocation.count
        let planBlocks = visiblePlans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        let travelBlocks = visibleTravel.map { travel in
            timelineBlock(
                id: travel.id,
                title: travelModeName(travel.mode),
                span: travel.span,
                top: compactAutomaticTop(
                    offset
                        + travelAllocation.lanes[travel.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText:
                    "자동 이동 · \(confidenceName(travel.confidence))",
                categoryID: "movement",
                categoryName: "이동"
            )
        }
        let actualBlocks = actuals.map { actual in
            timelineBlock(
                id: actual.id,
                title: movementActualTitle(actual),
                span: actual.span(asOf: now),
                top: compactAutomaticTop(
                    offset
                        + travelAllocation.count
                        + actualAllocation.lanes[actual.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText:
                    "자동 이동 · \(actualSourceName(actual.source))",
                categoryID: "movement",
                categoryName: "이동"
            )
        }
        return TimelineRowModel(
            title: "이동",
            id: "movement",
            category: .movement,
            categoryID: "movement",
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count
                    + travelAllocation.count
                    + actualAllocation.count
            ),
            blocks: planBlocks + travelBlocks + actualBlocks
        )
    }

    private func automaticActivityRow(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let visiblePlans = plans.filter { $0.span.start <= Date.now }
        let planAllocation = laneAllocation(visiblePlans, span: \.span)
        let actualAllocation = laneAllocation(actuals, span: { $0.span() })
        let offset = planAllocation.count
        let planBlocks = visiblePlans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        return TimelineRowModel(
            title: "활동",
            id: "activity",
            category: .activity,
            categoryID: "activity",
            dotColor: .tpHealthDark,
            fillColor: .tpHealthArea,
            actualColor: .tpHealthDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + actualAllocation.count
            ),
            blocks: planBlocks + actuals.map { actual in
                timelineBlock(
                    id: actual.id,
                    title: actual.title,
                    span: actual.span(),
                    top: compactAutomaticTop(
                        offset + actualAllocation.lanes[actual.id, default: 0]
                    ),
                    height: 14,
                    isFixed: true,
                    status: .completed,
                    isActual: true,
                    detailText:
                        "자동 활동 · \(actualSourceName(actual.source))",
                    categoryID: "activity",
                    categoryName: "활동"
                )
            }
        )
    }

    private func automaticSleepRow(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let visiblePlans = plans.filter { $0.span.start <= Date.now }
        let planAllocation = laneAllocation(visiblePlans, span: \.span)
        let actualAllocation = laneAllocation(actuals, span: { $0.span() })
        let offset = planAllocation.count
        let planBlocks = visiblePlans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        return TimelineRowModel(
            title: "수면",
            id: "sleep",
            category: .sleep,
            categoryID: "sleep",
            dotColor: .tpSleepDark,
            fillColor: .tpSleep,
            actualColor: .tpSleepDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + actualAllocation.count
            ),
            blocks: planBlocks + actuals.map { actual in
                timelineBlock(
                    id: actual.id,
                    title: actual.title,
                    span: actual.span(),
                    top: compactAutomaticTop(
                        offset + actualAllocation.lanes[actual.id, default: 0]
                    ),
                    height: 14,
                    isFixed: true,
                    status: .completed,
                    isActual: true,
                    detailText:
                        "자동 수면 · \(actualSourceName(actual.source))",
                    categoryID: "sleep",
                    categoryName: "수면"
                )
            }
        )
    }

    private func compactAutomaticHeight(_ laneCount: Int) -> CGFloat {
        10 + CGFloat(max(1, laneCount)) * 18
    }

    private func compactAutomaticTop(_ lane: Int) -> CGFloat {
        5 + CGFloat(lane) * 18
    }

    private func calendarDetailText(_ event: CalendarRecord) -> String {
        [
            calendarEventDateTimeLabel(for: event),
            event.sourceTitle,
            event.calendarTitle,
            "고정 일정",
        ]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = max(
            0,
            min(
                weekdaySymbols.count - 1,
                calendar.component(.weekday, from: date) - 1
            )
        )
        return "\(month)월 \(day)일 (\(weekdaySymbols[weekdayIndex]))"
    }

    private func timelineBlock(
        plan: PlanRecord,
        index: TimelineBoardDataIndex,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        let childCount = index.childCounts[plan.id, default: 0]
        let categoryName = index.categoryNames[plan.categoryID]
            ?? plan.categoryID
        let categoryDetail = PlanCategoryPathPresentation.detail(
            categoryName: categoryName,
            key: PlanCategoryPathPresentation.key(for: plan)
        )
        let isGoalPlan = isGoalPlan(plan)
        let displayTitle = isGoalPlan
            ? goalDisplayTitle(plan.title)
            : plan.title
        return timelineBlock(
            id: plan.id,
            planID: plan.id,
            title: displayTitle,
            span: plan.span,
            top: top,
            height: height,
            isFixed: plan.isFixed
                || plan.origin == .repeatRule
                || plan.origin == .health
                || plan.origin == .location
                || plan.origin == .motion,
            groupCount: childCount > 0 ? childCount : nil,
            status: plan.status,
            detailText: isGoalPlan
                ? "루틴 · \(categoryDetail)"
                : ["계획", categoryDetail]
                .joined(separator: " · "),
            isGoal: isGoalPlan,
            categoryID: plan.categoryID,
            categoryName: categoryDetail
        )
    }

    private func isGoalPlan(_ plan: PlanRecord) -> Bool {
        // Only an explicit goal or a generated repeat segment gets goal
        // styling. A regular plan having child items is still a plan; the
        // mere existence of descendants must not invent a goal in details.
        if plan.origin == .repeatRule {
            return true
        }
        return GoalRecordPolicy.isGoal(plan)
    }

    private func goalDisplayTitle(_ title: String) -> String {
        GoalRecordPolicy.displayTitle(title)
    }

    private func timelineBlock(
        actual: ActualRecord,
        index: TimelineBoardDataIndex,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        timelineBlock(
            id: actual.id,
            title: "\(actual.title) · 실제",
            span: actual.span(),
            top: top,
            height: height,
            isFixed: true,
            status: .completed,
            isActual: true,
            detailText:
                "실제 · \(actualSourceName(actual.source)) · \(confidenceName(actual.confidence))",
            categoryID: actual.categoryID,
            categoryName: index.categoryNames[actual.categoryID]
        )
    }

    private func sensorTimelineBlocks(
        categoryID: String,
        top: CGFloat,
        visibleSpan: TimeSpan
    ) -> [TimelineBlock] {
        let now = Date.now
        switch categoryID {
        case "movement":
            let visibleTravel: [TravelSegment] = model.snapshot.travel.compactMap {
                travel in
                guard let clipped = automaticSpanThroughNow(
                    travel.span,
                    asOf: now
                ), clipped.intersection(with: visibleSpan) != nil else {
                    return nil
                }
                var value = travel
                value.span = clipped
                return value
            }
            return visibleTravel
                .sorted { $0.span.start < $1.span.start }
                .map { travel in
                    timelineBlock(
                        id: travel.id,
                        title: travelModeName(travel.mode),
                        span: travel.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            "센서 추정 · \(confidenceName(travel.confidence))",
                        categoryID: "movement",
                        categoryName: "이동"
                    )
                }
        case "location":
            let visiblePlaces: [PlaceStay] = model.snapshot.places.compactMap {
                place in
                guard let clipped = automaticSpanThroughNow(
                    place.span,
                    asOf: now
                ), clipped.intersection(with: visibleSpan) != nil else {
                    return nil
                }
                var value = place
                value.span = clipped
                return value
            }
            return visiblePlaces
                .sorted { $0.span.start < $1.span.start }
                .map { place in
                    let title = place.floor.map {
                        "\(place.displayName) · \($0)층"
                    } ?? place.displayName
                    let altitude = place.point.map {
                        "해발 \(Int($0.altitude.rounded()))m"
                            + (
                                $0.verticalAccuracy >= 0
                                    ? " · ±\(Int($0.verticalAccuracy.rounded()))m"
                                    : ""
                            )
                    }
                    return timelineBlock(
                        id: place.id,
                        title: title,
                        span: place.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            [
                                "센서 추정",
                                confidenceName(place.confidence),
                                altitude,
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        categoryID: "location",
                        categoryName: "위치"
                    )
                }
        default:
            return []
        }
    }

    private func travelModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자동차"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    private func confidenceName(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    private func actualSourceName(_ source: ActualSource) -> String {
        switch source {
        case .manual: "직접 기록"
        case .timer: "타이머"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch 센서"
        case .motion: "iPhone Core Motion"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func laneAllocation<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> (lanes: [Item.ID: Int], count: Int)
    where Item.ID: Hashable {
        let allocation = TimelineLaneAllocator.allocate(items, span: span)
        return (allocation.lanes, allocation.count)
    }

    private func timelineBlock(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        span: TimeSpan,
        top: CGFloat,
        height: CGFloat,
        isFixed: Bool,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        detailText: String? = nil,
        isGoal: Bool = false,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) -> TimelineBlock {
        let overlap = span.intersection(with: layoutDataSpan) ?? span
        let start = CGFloat(
            timelineFraction(of: overlap.start, in: layoutDataSpan)
        )
        let end = CGFloat(
            timelineFraction(of: overlap.end, in: layoutDataSpan)
        )
        let length = max(0, end - start)
        return TimelineBlock(
            id: id,
            planID: planID,
            title: title,
            start: max(0, min(1, start)),
            length: max(0.012, min(1, length)),
            top: top,
            height: height,
            isFixed: isFixed,
            groupCount: groupCount,
            actualFraction: actualFraction,
            status: status,
            isActual: isActual,
            opensLocationTimeline: opensLocationTimeline,
            startsAt: span.start,
            endsAt: span.end,
            detailText: detailText,
            categoryID: categoryID,
            categoryName: categoryName,
            isGoal: isGoal
        )
    }

    private var isContinuousDay: Bool {
        scale == .day
    }

    /// Every resolution now uses the same continuous playhead model. Day
    /// keeps its selected zoom duration; week/month/year retain the calendar
    /// period's initial width while the center moves through adjacent periods.
    private var isContinuousTimeline: Bool {
        switch scale {
        case .day, .week, .month, .year:
            true
        }
    }

    private func continuousDuration(around date: Date) -> TimeInterval {
        if scale == .day {
            return max(60, dayZoom.duration)
        }
        return max(
            86_400,
            TimelineAxisGrid.span(for: scale, containing: date).duration
        )
    }

    private var activeContinuousDuration: TimeInterval {
        return max(
            60,
            continuousTimelineDuration > 0
                ? continuousTimelineDuration
                : continuousDuration(around: continuousCenterDate)
        )
    }

    private var hasCustomContinuousDuration: Bool {
        let standard = continuousDuration(around: continuousCenterDate)
        return abs(activeContinuousDuration - standard) > 1
    }

    private var layoutDataSpan: TimeSpan {
        dragLayoutSpan ?? visibleSpan
    }

    private func timelineFraction(
        of date: Date,
        in span: TimeSpan
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        return date.timeIntervalSince(span.start) / span.duration
    }

    private func timelineDate(
        at fraction: Double,
        in span: TimeSpan
    ) -> Date {
        span.start.addingTimeInterval(
            span.duration * min(1, max(0, fraction))
        )
    }

    private func ensureContinuousLayoutWindow(around center: Date) {
        guard isContinuousTimeline else { return }

        // Keep a hysteresis band around the cached window. A drag can cross
        // several days, and a pinch can zoom out beyond the original span;
        // recenter only when the current window is no longer sufficient so
        // normal touch samples remain cache hits.
        let minimumWindowDuration = max(60, activeContinuousDuration * 3)
        if let current = dragLayoutSpan,
           current.duration >= minimumWindowDuration {
            let margin = current.duration * 0.25
            let safeStart = current.start.addingTimeInterval(margin)
            let safeEnd = current.end.addingTimeInterval(-margin)
            if safeStart <= center, center <= safeEnd {
                return
            }
        }

        let windowDuration = max(
            minimumWindowDuration,
            dragLayoutSpan?.duration ?? 0
        )
        let halfDuration = windowDuration / 2
        dragLayoutSpan = TimeSpan(
            start: center.addingTimeInterval(-halfDuration),
            end: center.addingTimeInterval(halfDuration)
        )
    }

    private var standardVisibleSpan: TimeSpan {
        TimelineAxisGrid.span(
            for: scale,
            containing: model.selectedDate
        )
    }

    private var visibleSpan: TimeSpan {
        guard isContinuousTimeline else { return standardVisibleSpan }
        let halfDuration = activeContinuousDuration / 2
        return TimeSpan(
            start: continuousCenterDate.addingTimeInterval(-halfDuration),
            end: continuousCenterDate.addingTimeInterval(halfDuration)
        )
    }

    @ViewBuilder
    private func gridLines(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: scheduleLabelColumnWidth)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        Rectangle()
                            .fill(ganttTableLineColor)
                            .frame(width: 0.5)
                            .position(
                                x: proxy.size.width
                                    * CGFloat(marker.fraction),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func currentLine() -> some View {
        if isContinuousTimeline {
            GeometryReader { proxy in
                let x = scheduleLabelColumnWidth
                    + max(1, proxy.size.width - scheduleLabelColumnWidth) / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 9, height: 9)
                        .position(x: x, y: 1)
                    Text(
                        continuousCenterDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .position(x: x, y: 7)
                }
            }
            .zIndex(20)
        } else {
            GeometryReader { proxy in
                let timelineWidth = max(
                    1,
                    proxy.size.width - scheduleLabelColumnWidth
                )
                let x = scheduleLabelColumnWidth + timelineWidth / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: 1)
                    Text(playheadAxisLabel(continuousCenterDate))
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .position(x: x, y: 7)
                }
            }
            .zIndex(20)
        }
    }

    private func photoRow(_ clusters: [PhotoCluster]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tpPhotoDark)
                    .frame(width: 8, height: 8)
                Text("사진")
                    .font(.taption(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.tpInk)
            .padding(.leading, 8)
            .frame(
                width: scheduleLabelColumnWidth,
                alignment: .leading
            )

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(clusters) { cluster in
                        if let x = photoMarkerX(
                            cluster,
                            width: proxy.size.width
                        ) {
                            photoMarker(cluster: cluster, x: x)
                        }
                    }
                }
            }
            .clipped()
        }
        .frame(height: 65)
        .background(Color(red: 0.99, green: 0.98, blue: 1.00))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private func photoMarker(
        cluster: PhotoCluster,
        x: CGFloat
    ) -> some View {
        Button {
            onPhotoSelection?(cluster)
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    PhotoAssetThumbnail(
                        model: model,
                        localIdentifier: cluster.representative.id
                    )
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white, lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(0.24), radius: 2.5, y: 1)

                    if cluster.additionalCount > 0 {
                        Text("+\(cluster.additionalCount)")
                            .font(.taption(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Color.tpPhotoDark, in: Capsule())
                            .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
                            .offset(x: 5, y: -5)
                    }
                }
                Text(
                    cluster.capturedAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                    .font(.taption(size: 6.5, weight: .black))
                    .foregroundStyle(Color.tpPhotoDark)
            }
        }
        .buttonStyle(.plain)
        .position(
            x: x,
            y: 32
        )
    }

    private func photoMarkerX(
        _ cluster: PhotoCluster,
        width: CGFloat
    ) -> CGFloat? {
        let fraction = timelineFraction(
            of: cluster.capturedAt,
            in: visibleSpan
        )
        guard viewport.start <= fraction, fraction <= viewport.end else {
            return nil
        }
        let viewportFraction =
            (fraction - viewport.start) / viewport.length
        return min(
            width - 22,
            max(22, width * CGFloat(viewportFraction))
        )
    }

    private func summaryStrip(
        buckets: [SummaryBucket],
        colors: [SummaryColor]
    ) -> some View {
        HStack(spacing: 0) {
            Text(summaryTitle)
                .font(.taption(size: scale == .month ? 9 : 10, weight: .regular))
                .foregroundStyle(Color.tpSecondary)
                .padding(.leading, scale == .month ? 4 : 8)
                .frame(
                    width: scheduleLabelColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: 3) {
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        zoomIntoSummary(buckets[index])
                    } label: {
                        ZStack {
                            RoundedRectangle(
                                cornerRadius: 5,
                                style: .continuous
                            )
                            .fill(
                                colors[index].color.opacity(
                                    colors[index].opacity
                                )
                            )
                            if buckets[index].photoCount > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "photo.fill")
                                    Text(
                                        "\(buckets[index].photoCount)"
                                    )
                                }
                                .font(.taption(size: 6.5, weight: .black))
                                .foregroundStyle(Color.tpPhotoDark)
                            }
                        }
                        .frame(height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        summaryAccessibilityLabel(
                            buckets[index]
                        )
                    )
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 46)
        .background(Color(red: 0.98, green: 0.98, blue: 0.985))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월·주·일 요약"
        }
    }

    private func summaryColors(
        for buckets: [SummaryBucket]
    ) -> [SummaryColor] {
        let maximum = max(
            1,
            buckets.map {
                max($0.actualDuration, $0.plannedDuration)
            }.max() ?? 1
        )
        return buckets.map { bucket in
            let dominant = bucket.categories.max {
                max($0.actual, $0.planned) < max($1.actual, $1.planned)
            }
            let definition = dominant.flatMap { value in
                model.snapshot.categories.first {
                    $0.id == value.categoryID
                }
            }
            let activity = max(bucket.actualDuration, bucket.plannedDuration)
            return SummaryColor(
                Color(hex: definition?.darkHex ?? "#D9D9DD"),
                activity == 0 ? 0.18 : 0.25 + 0.70 * activity / maximum
            )
        }
    }

    private func nowFraction(at date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    timelineFraction(of: date, in: visibleSpan)
                )
            )
        )
    }

    private var viewportMinimumLength: Double {
        GanttViewport.oneMinuteMinimumLength(
            for: visibleSpan.duration
        )
    }

    private var viewportVisibleSpan: TimeSpan {
        TimeSpan(
            start: timelineDate(at: viewport.start, in: visibleSpan),
            end: timelineDate(at: viewport.end, in: visibleSpan)
        )
    }

    private func axisMarkers(in visibleSpan: TimeSpan) -> [TimelineAxisMarker] {
        if isContinuousTimeline {
            return continuousAxisMarkers(
                in: viewport.isFull ? visibleSpan : viewportVisibleSpan
            )
        }
        guard !viewport.isFull else {
            return TimelineAxisGrid.buckets(
                for: scale,
                containing: model.selectedDate
            ).map { bucket in
                TimelineAxisMarker(
                    id: "full-\(bucket.id)",
                    date: bucket.date,
                    fraction: Double(bucket.index) / Double(bucket.count),
                    label: bucket.label,
                    isCurrent: isCurrentBucket(bucket),
                    holidayName: bucket.holidayName
                )
            }
        }

        let span = viewportVisibleSpan
        let step = axisTickInterval
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var next = ceil(start / step) * step
        var markers: [TimelineAxisMarker] = []

        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            markers.append(
                TimelineAxisMarker(
                    id: "zoom-\(next)",
                    date: date,
                    fraction: (next - start) / max(1, end - start),
                    label: axisTickLabel(date),
                    isCurrent: abs(date.timeIntervalSinceNow) < step / 2
                )
            )
            next += step
        }

        if markers.isEmpty {
            let date = span.start.addingTimeInterval(span.duration / 2)
            return [
                TimelineAxisMarker(
                    id: "zoom-center-\(date.timeIntervalSinceReferenceDate)",
                    date: date,
                    fraction: 0.5,
                    label: axisTickLabel(date),
                    isCurrent: span.contains(.now)
                )
            ]
        }
        return markers
    }

    private func continuousAxisMarkers(
        in span: TimeSpan
    ) -> [TimelineAxisMarker] {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        let zoomDuration = span.duration
        let component: Calendar.Component
        let componentValue: Int
        let step: TimeInterval
        switch scale {
        case .day:
            component = .minute
            switch zoomDuration {
            case ...Double(5 * 60): componentValue = 1
            case ...Double(15 * 60): componentValue = 5
            case ...Double(60 * 60): componentValue = 10
            case ...Double(6 * 60 * 60): componentValue = 30
            case ...Double(12 * 60 * 60): componentValue = 60
            case ...Double(24 * 60 * 60): componentValue = 120
            case ...Double(3 * 24 * 60 * 60): componentValue = 360
            default: componentValue = 1_440
            }
            step = Double(componentValue * 60)
        case .week:
            component = .day
            componentValue = 1
            step = 86_400
        case .month:
            component = .day
            componentValue = span.duration <= 14 * 86_400 ? 1 : 2
            step = Double(componentValue) * 86_400
        case .year:
            component = .month
            componentValue = 1
            step = 31 * 86_400
        }
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var nextDate: Date
        if scale == .year {
            nextDate = calendar.dateInterval(of: .month, for: span.start)?.start
                ?? span.start
        } else if scale == .day {
            nextDate = calendar.startOfDay(for: span.start)
        } else {
            nextDate = calendar.startOfDay(for: span.start)
        }
        while nextDate < span.start {
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
        }
        var next = nextDate.timeIntervalSinceReferenceDate
        var markers: [TimelineAxisMarker] = []
        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            let label: String
            if scale == .day && zoomDuration <= 6 * 60 * 60 {
                label = axisHourMinuteLabel(date, calendar: calendar)
            } else if scale == .day && zoomDuration <= 24 * 60 * 60 {
                let hour = calendar.component(.hour, from: date)
                label = String(format: "%02d", hour)
            } else if scale == .year {
                label = "\(calendar.component(.month, from: date))월"
            } else if scale == .week {
                label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
            } else {
                label = "\(calendar.component(.day, from: date))"
            }
            markers.append(
                TimelineAxisMarker(
                    id: "continuous-\(next)",
                    date: date,
                    fraction: (next - start) / max(1, end - start),
                    label: label,
                    isCurrent: abs(date.timeIntervalSince(continuousCenterDate))
                        < step / 2
                )
            )
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
            next = nextDate.timeIntervalSinceReferenceDate
        }
        return markers
    }

    private func isCurrentBucket(_ bucket: TimelineAxisBucket) -> Bool {
        switch scale {
        case .week:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                inSameDayAs: model.selectedDate
            )
        case .month:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .day
            )
        case .year:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .month
            )
        case .day:
            return false
        }
    }

    private var axisTickInterval: TimeInterval {
        let target = viewportVisibleSpan.duration / 6
        let supportedSteps: [TimeInterval] = [
            60,
            5 * 60,
            15 * 60,
            30 * 60,
            60 * 60,
            3 * 60 * 60,
            6 * 60 * 60,
            12 * 60 * 60,
            24 * 60 * 60,
            2 * 24 * 60 * 60,
            5 * 24 * 60 * 60,
            7 * 24 * 60 * 60,
            14 * 24 * 60 * 60,
            30 * 24 * 60 * 60,
            90 * 24 * 60 * 60,
        ]
        return supportedSteps.first { $0 >= target }
            ?? supportedSteps.last!
    }

    private func axisTickLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if viewportVisibleSpan.duration <= 60 * 60 {
            return axisHourMinuteLabel(date, calendar: calendar)
        }
        if viewportVisibleSpan.duration <= 2 * 24 * 60 * 60 {
            return String(format: "%02d", calendar.component(.hour, from: date))
        }
        if viewportVisibleSpan.duration <= 90 * 24 * 60 * 60 {
            return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
        }
        return "\(calendar.component(.month, from: date))월"
    }

    private func axisHourMinuteLabel(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }

    private func markerX(
        _ marker: TimelineAxisMarker,
        width: CGFloat
    ) -> CGFloat {
        min(
            max(18, width - 18),
            max(18, width * CGFloat(marker.fraction))
        )
    }

    private var currentAxisLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        return switch scale {
        case .day:
            String(format: "%02d", calendar.component(.hour, from: .now))
        case .week:
            Date.now.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
        case .month:
            "\(calendar.component(.day, from: .now))"
        case .year:
            "\(calendar.component(.month, from: .now))"
        }
    }

    private func playheadAxisLabel(_ date: Date) -> String {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        switch scale {
        case .day:
            return date.formatted(date: .omitted, time: .shortened)
        case .week:
            let weekday = date.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일 \(weekday)"
        case .month:
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일"
        case .year:
            return "\(calendar.component(.year, from: date))년 \(calendar.component(.month, from: date))월"
        }
    }

    private func photoClusters(in visibleSpan: TimeSpan) -> [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt)
            }
        )
    }

    private func summaryBuckets(in visibleSpan: TimeSpan) -> [SummaryBucket] {
        let childLevel: TimelineLevel
        switch scale {
        case .day:
            return []
        case .week:
            childLevel = .day
        case .month:
            childLevel = .week
        case .year:
            childLevel = .month
        }
        return TimelineAggregationEngine().hierarchySummaries(
            for: scale.timelineLevel,
            containing: model.selectedDate,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            photos: model.snapshot.photos
        )[childLevel] ?? []
    }

    private func zoomIntoSummary(_ bucket: SummaryBucket) {
        model.selectedDate = bucket.span.start
        switch scale {
        case .week:
            selectScaleForResolution(.day)
        case .month:
            selectScaleForResolution(.week)
        case .year:
            selectScaleForResolution(.month)
        case .day:
            break
        }
    }

    private func summaryAccessibilityLabel(
        _ bucket: SummaryBucket
    ) -> String {
        let range =
            bucket.span.start.formatted(.dateTime.month().day())
            + "부터 "
            + bucket.span.end.addingTimeInterval(-1)
                .formatted(.dateTime.month().day())
        let photoText = bucket.photoCount > 0
            ? ", 사진 \(bucket.photoCount)장"
            : ""
        return "\(range) 요약\(photoText), 탭하여 확대"
    }

    private func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard editingPlanID == nil,
                      abs(value.translation.width)
                        > abs(value.translation.height) else {
                    return
                }
                if isContinuousTimeline {
                    if continuousDragOrigin == nil {
                        continuousDragOrigin = continuousCenterDate
                        continuousTimelineDuration = visibleSpan.duration
                        let currentSpan = visibleSpan
                        dragLayoutSpan = TimeSpan(
                            start: currentSpan.start.addingTimeInterval(
                                -currentSpan.duration
                            ),
                            end: currentSpan.end.addingTimeInterval(
                                currentSpan.duration
                            )
                        )
                        editingPlanID = nil
                        lastContinuousRenderUptime = 0
                    }
                    guard let continuousDragOrigin else { return }
                    let secondsPerPoint = activeContinuousDuration
                        * viewport.length
                        / Double(max(1, width))
                    let candidate = continuousDragOrigin.addingTimeInterval(
                        -Double(value.translation.width) * secondsPerPoint
                    )
                    ensureContinuousLayoutWindow(around: candidate)
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard lastContinuousRenderUptime == 0
                        || uptime - lastContinuousRenderUptime >= 1.0 / 60.0
                    else {
                        return
                    }
                    lastContinuousRenderUptime = uptime
                    continuousCenterDate = candidate
                    onPlayheadMove?(continuousCenterDate)
                } else {
                    if dragOrigin == nil {
                        dragOrigin = viewport
                    }
                    guard let dragOrigin else { return }
                    let candidate = dragOrigin.panning(
                        translation: Double(value.translation.width),
                        viewportWidth: Double(width)
                    )
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard lastViewportRenderUptime == 0
                        || uptime - lastViewportRenderUptime >= 1.0 / 60.0
                    else {
                        return
                    }
                    lastViewportRenderUptime = uptime
                    viewport = candidate
                }
            }
            .onEnded { value in
                if isContinuousTimeline {
                    var finalDate = continuousCenterDate
                    if let continuousDragOrigin {
                        let secondsPerPoint = activeContinuousDuration
                            * viewport.length
                            / Double(max(1, width))
                        finalDate = continuousDragOrigin
                            .addingTimeInterval(
                                -Double(value.translation.width)
                                    * secondsPerPoint
                            )
                    }
                    let direction: TimelinePlayheadSynchronizer.Direction =
                        value.translation.width < 0 ? .forward : .backward
                    finalDate = TimelinePlayheadSynchronizer.snapIfNeeded(
                        date: finalDate,
                        direction: direction,
                        plans: model.snapshot.plans,
                        actuals: model.snapshot.actuals,
                        places: model.snapshot.places,
                        travel: model.snapshot.travel,
                        calendarEvents: model.snapshot.calendarEvents,
                        weather: model.snapshot.weather,
                        photos: PhotoClusterer.cluster(model.snapshot.photos)
                    )
                    continuousCenterDate = finalDate
                    // Changing the selected date normally resets the
                    // viewport. A continuous drag is different: it pans the
                    // already zoomed range, so keep that zoom after commit.
                    preserveViewportAfterContinuousDrag = true
                    let preservedViewport = viewport
                    model.selectedDate = finalDate
                    onPlayheadMove?(finalDate)
                    // Restore synchronously as well as in the selected-date
                    // observer. This covers the case where the parent view
                    // re-renders before that observer is delivered.
                    viewport = preservedViewport
                    lastContinuousRenderUptime = 0
                    dragLayoutSpan = nil
                } else if let dragOrigin {
                    // Commit the final sample even when the last 240 Hz
                    // callback arrived inside the 60 Hz presentation gate.
                    viewport = dragOrigin.panning(
                        translation: Double(value.translation.width),
                        viewportWidth: Double(width)
                    )
                    if dragOrigin.isFull,
                       abs(value.translation.width) > width * 0.18 {
                        // At the default full-period view, a horizontal swipe
                        // crosses the period boundary instead of stopping at
                        // the edge. Zoomed views retain the existing free pan.
                        model.shiftSelectedDate(
                            by: value.translation.width < 0 ? 1 : -1
                        )
                    }
                }
                dragOrigin = nil
                continuousDragOrigin = nil
                lastViewportRenderUptime = 0
            }
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                viewportMagnifyChanged(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
            .onEnded { value in
                viewportMagnifyEnded(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
    }

    private func viewportMagnifyChanged(
        factor: Double,
        anchor: Double
    ) {
        if magnifyOrigin == nil {
            magnifyOrigin = viewport
            editingPlanID = nil
            if isContinuousTimeline {
                let originSpan = visibleSpan
                let clampedAnchor = min(1, max(0, anchor))
                let anchorFraction = viewport.start
                    + viewport.length * clampedAnchor
                continuousMagnifyOrigin = ContinuousMagnifyOrigin(
                    duration: max(
                        60,
                        originSpan.duration * viewport.length
                    ),
                    anchorDate: timelineDate(
                        at: anchorFraction,
                        in: originSpan
                    ),
                    anchor: clampedAnchor
                )
                // The live duration becomes the source of truth.  Do not
                // leave a second viewport multiplier behind to quantize it.
                viewport = .full
                dragLayoutSpan = nil
            }
        }
        guard let magnifyOrigin else { return }
        if continuousMagnifyOrigin != nil {
            applyContinuousMagnification(
                factor: factor,
                force: false
            )
            return
        }
        let candidate = magnifyOrigin.magnifying(
            by: factor,
            anchor: anchor,
            minimumLength: viewportMinimumLength
        )
        let uptime = ProcessInfo.processInfo.systemUptime
        guard lastViewportRenderUptime == 0
            || uptime - lastViewportRenderUptime >= 1.0 / 60.0
        else {
            return
        }
        lastViewportRenderUptime = uptime
        viewport = candidate
    }

    private func viewportMagnifyEnded(
        factor: Double,
        anchor: Double
    ) {
        guard magnifyOrigin != nil else { return }
        finishSemanticMagnification(
            factor: factor,
            anchor: anchor
        )
        magnifyOrigin = nil
        lastViewportRenderUptime = 0
    }

    private func finishSemanticMagnification(
        factor: Double,
        anchor: Double
    ) {
        if continuousMagnifyOrigin != nil {
            applyContinuousMagnification(factor: factor, force: true)
            let finalCenter = continuousCenterDate
            continuousMagnifyOrigin = nil
            viewport = .full
            preserveViewportAfterContinuousDrag = true
            model.selectedDate = finalCenter
            onPlayheadMove?(finalCenter)
            zoomFeedbackSequence += 1
            return
        }

        let origin = magnifyOrigin ?? viewport
        let zoomsIn = factor >= 1.15
        let zoomsOut = factor <= 0.85
        guard zoomsIn || zoomsOut else {
            // The live viewport already follows the fingers. Do not snap a
            // small but intentional pinch back to the pre-gesture range.
            return
        }

        if scale != .day {
            let targetScale = zoomsIn ? scale.narrower : scale.broader
            guard let targetScale else {
                viewport = origin
                return
            }
            transitionScale(
                to: targetScale,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let originStage = GanttZoomStage.nearest(
            to: visibleSpan.duration * origin.length
        )
        if zoomsOut, originStage == .day {
            guard let broader = scale.broader else {
                viewport = origin
                return
            }
            transitionScale(
                to: broader,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let targetStage = zoomsIn
            ? originStage.narrower
            : originStage.broader
        guard let targetStage, targetStage >= .day else {
            viewport = origin
            return
        }
        viewport = origin.fitting(
            visibleDuration: targetStage.duration,
            within: visibleSpan.duration,
            anchor: anchor
        )
        zoomFeedbackSequence += 1
    }

    private func transitionScale(
        to targetScale: TimeScale,
        origin: GanttViewport,
        anchor: Double
    ) {
        let clampedAnchor = min(1, max(0, anchor))
        let anchorFraction =
            origin.start + origin.length * clampedAnchor
        model.selectedDate = timelineDate(
            at: anchorFraction,
            in: visibleSpan
        )
        viewport = .full
        selectScaleForResolution(targetScale)
        zoomFeedbackSequence += 1
    }

    private func applyContinuousMagnification(
        factor: Double,
        force: Bool
    ) {
        guard let origin = continuousMagnifyOrigin else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force
            || lastViewportRenderUptime == 0
            || uptime - lastViewportRenderUptime >= 1.0 / 60.0
        else {
            return
        }
        lastViewportRenderUptime = uptime

        let safeFactor = max(0.01, factor)
        let minimumDuration: TimeInterval = 60
        let maximumDuration: TimeInterval = 10 * 366 * 24 * 60 * 60
        let duration = min(
            maximumDuration,
            max(minimumDuration, origin.duration / safeFactor)
        )
        let center = origin.anchorDate.addingTimeInterval(
            duration * (0.5 - origin.anchor)
        )
        if continuousTimelineDuration != duration {
            continuousTimelineDuration = duration
        }
        if continuousCenterDate != center {
            continuousCenterDate = center
            onPlayheadMove?(center)
        }
        viewport = .full
        ensureContinuousLayoutWindow(around: center)
    }

    private func resetViewport(withFeedback: Bool = false) {
        let changed = !viewport.isFull || hasCustomContinuousDuration
        if isContinuousTimeline {
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            if isContinuousDay {
                dayZoom = .oneHour
            }
            continuousDragOrigin = nil
        }
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        continuousMagnifyOrigin = nil
        editingPlanID = nil
        if withFeedback, changed {
            zoomFeedbackSequence += 1
        }
    }

    private func handleRowTap(_ row: TimelineRowModel) {
        selectedRowID = row.id
        let selectableBlocks = row.blocks
            .filter { !$0.isActual && $0.planID != nil }
            .sorted {
                ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast)
            }
        if let block = selectableBlocks.first {
            onSelection?(selectionFromBlock(block))
            return
        }

        guard let categoryID = row.categoryID else { return }
        if categoryID == "calendar" {
            onSelection?(
                TimelineSelection(
                    title: "일정",
                    span: visibleSpan,
                    planID: nil,
                    isRoute: false,
                    categoryID: "calendar",
                    categoryName: "일정"
                )
            )
            return
        }
        if TaptionProductScope.automaticLoggingOnly {
            onSelection?(
                TimelineSelection(
                    title: row.title,
                    span: visibleSpan,
                    planID: nil,
                    isRoute: categoryID == "movement"
                        || categoryID == "location",
                    categoryID: categoryID,
                    categoryName: row.title
                )
            )
            return
        }
        let memoPlan = model.memoPlan(
            forCategoryID: categoryID,
            categoryName: row.title,
            near: model.selectedDate
        )
        onSelection?(
            TimelineSelection(
                title: row.title,
                span: memoPlan.span,
                planID: memoPlan.id,
                isRoute: categoryID == "movement" || categoryID == "location",
                categoryID: categoryID,
                categoryName: row.title
            )
        )
    }

    private func focusOnBlock(_ block: TimelineBlock) {
        let selection = selectionFromBlock(block)
        onFocus?(selection)
        onSelection?(selection)

        if isContinuousTimeline,
           let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            continuousCenterDate = startsAt.addingTimeInterval(
                max(0, endsAt.timeIntervalSince(startsAt)) / 2
            )
            model.selectedDate = continuousCenterDate
            if scale == .day {
                dayZoom = TimelineZoomPreset.nearest(
                    to: max(60, endsAt.timeIntervalSince(startsAt) * 6)
                )
            } else {
                continuousTimelineDuration = continuousDuration(
                    around: continuousCenterDate
                )
            }
            editingPlanID = nil
            zoomFeedbackSequence += 1
            return
        }
        let blockStart: Double
        let blockLength: Double
        if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            blockStart = timelineFraction(of: startsAt, in: visibleSpan)
            blockLength = timelineFraction(of: endsAt, in: visibleSpan)
                - blockStart
        } else {
            blockStart = Double(block.start)
            blockLength = Double(block.length)
        }

        viewport = GanttViewport.full.focusing(
            start: blockStart,
            length: blockLength,
            minimumLength: viewportMinimumLength
        )
        editingPlanID = nil
        zoomFeedbackSequence += 1
    }

    private func handleTap(_ block: TimelineBlock) {
        onSelection?(
            selectionFromBlock(block)
        )
        if block.opensLocationTimeline {
            return
        }

        if block.groupCount != nil {
            if let planID = block.planID {
                model.openGroup(planID)
            }
            return
        }

    }

    private func selectionFromBlock(_ block: TimelineBlock) -> TimelineSelection {
        let selectionSpan: TimeSpan = {
            if let startsAt = block.startsAt, let endsAt = block.endsAt {
                return TimeSpan(start: startsAt, end: endsAt)
            }
            let start = timelineDate(
                at: Double(block.start),
                in: visibleSpan
            )
            let end = timelineDate(
                at: min(1, Double(block.start + block.length)),
                in: visibleSpan
            )
            return TimeSpan(
                start: start,
                end: max(
                    start.addingTimeInterval(60),
                    end
                )
            )
        }()
        return TimelineSelection(
            title: block.title,
            span: selectionSpan,
            planID: block.planID,
            actualID: block.isActual
                && model.snapshot.actuals.contains(where: { $0.id == block.id })
                ? block.id
                : nil,
            travelID: block.categoryID == "movement" ? block.id : nil,
            recordNodeID: {
                if block.isActual {
                    if block.categoryID == "movement" {
                        return "automatic.travel.\(block.id.uuidString)"
                    }
                    if block.categoryID == "location" {
                        return "automatic.place.\(block.id.uuidString)"
                    }
                    if block.categoryID == "weather" {
                        return "automatic.weather.\(block.id.uuidString)"
                    }
                    return "automatic.actual.\(block.id.uuidString)"
                }
                if block.categoryID == "calendar" {
                    let event = model.snapshot.calendarEvents.first {
                        $0.title == block.title
                            && abs($0.span.start.timeIntervalSince(
                                selectionSpan.start
                            )) < 2
                    }
                    return event.map {
                        "automatic.calendar.\($0.id)"
                    }
                }
                if let planID = block.planID {
                    let isRoutine = model.snapshot.plans.first {
                        $0.id == planID
                    }.map(GoalRecordPolicy.isGoal) ?? false
                    return "\(isRoutine ? "routine" : "action").\(planID.uuidString)"
                }
                return nil
            }(),
            isRoute: block.opensLocationTimeline,
            categoryID: block.categoryID,
            categoryName: block.categoryName
        )
    }
}

private struct TimelineBlockSlice {
    let centerX: CGFloat
    let width: CGFloat
}

private struct TimelineRow: View {
    let row: TimelineRowModel
    let isSelected: Bool
    let editingPlanID: UUID?
    let visibleDuration: TimeInterval
    let viewport: GanttViewport
    let displaySpan: TimeSpan
    let scale: TimeScale
    let useCachedBlockFractions: Bool
    let onBlockTap: (TimelineBlock) -> Void
    let onBlockDoubleTap: (TimelineBlock) -> Void
    let onEdit: (UUID?) -> Void
    let onMove: (TimelineBlock, TimeInterval) -> Void
    let onResizeStart: (TimelineBlock, TimeInterval) -> Void
    let onResizeEnd: (TimelineBlock, TimeInterval) -> Void
    let onRowTap: () -> Void
    let onDrop: (String) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRowTap) {
                HStack(spacing: 4) {
                    if let iconName = row.iconName {
                        Image(systemName: iconName)
                            .font(.taption(size: 8.5, weight: .bold))
                            .foregroundStyle(row.dotColor)
                            .frame(width: 11, height: 11)
                    } else if row.dotColor != .clear {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.dotColor)
                            .frame(width: 8, height: 8)
                    }
                    Text(row.title)
                        .lineLimit(row.title.contains("\n") ? 3 : 1)
                        .minimumScaleFactor(0.78)
                        .lineSpacing(1)
                }
                .font(
                    .taption(
                        size: row.title.contains("\n")
                            ? 8.4
                            : (row.title.count > 4 ? 9 : 10.5),
                        weight: .semibold
                    )
                )
                .foregroundStyle(isSelected ? Color.tpInk : Color.tpInk)
                .padding(.leading, row.title.count > 4 ? 4 : 8)
                .padding(.trailing, 2)
                .frame(
                    width: scheduleLabelColumnWidth,
                    height: row.height,
                    alignment: .leading
                )
                .background(
                    isSelected
                        ? Color.tpInk.opacity(0.06)
                        : Color.clear
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.tpInk)
                            .frame(width: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture().onEnded {
                    onEdit(nil)
                }
            )
            .draggable(row.id)
            .dropDestination(for: String.self) { sourceIDs, _ in
                guard let sourceID = sourceIDs.first else { return false }
                return onDrop(sourceID)
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit(nil)
                        }

                    if row.isSystemAutomatic {
                        Rectangle()
                            .fill(Color.tpInk.opacity(0.026))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    ForEach(row.blocks) { block in
                        if let slice = visibleSlice(
                            for: block,
                            width: proxy.size.width
                        ) {
                            TimelineBar(
                                block: block,
                                color: row.fillColor,
                                actualColor: row.actualColor,
                                width: slice.width,
                                isEditing: editingPlanID == block.planID,
                                visibleDuration: visibleDuration,
                                secondsPerPoint:
                                    visibleDuration
                                    / max(1, proxy.size.width),
                                onTap: {
                                    if block.planID == nil {
                                        onEdit(nil)
                                    }
                                    onBlockTap(block)
                                },
                                onDoubleTap: {
                                    onBlockDoubleTap(block)
                                },
                                onEdit: { onEdit(block.planID) },
                                onMove: { onMove(block, $0) },
                                onResizeStart: {
                                    onResizeStart(block, $0)
                                },
                                onResizeEnd: {
                                    onResizeEnd(block, $0)
                                }
                            )
                                .position(
                                    x: slice.centerX,
                                    y: block.top + block.height / 2
                                )
                        }
                    }
                }
            }
            .clipped()
        }
        .background(
            row.isSystemAutomatic
                ? Color.tpInk.opacity(0.018)
                : Color.clear
        )
        .frame(height: row.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ganttTableLineColor)
                .frame(height: 0.5)
        }
    }

    private func visibleSlice(
        for block: TimelineBlock,
        width: CGFloat
    ) -> TimelineBlockSlice? {
        let blockStart: Double
        let blockEnd: Double
        if useCachedBlockFractions {
            blockStart = Double(block.start)
            blockEnd = blockStart + Double(block.length)
        } else if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            // All four resolutions use a continuous time coordinate while
            // dragging. This keeps a block moving at a constant speed across
            // week/month/year boundaries instead of snapping to calendar
            // bucket edges.
            let duration = max(1, displaySpan.duration)
            blockStart = startsAt.timeIntervalSince(displaySpan.start)
                / duration
            blockEnd = endsAt.timeIntervalSince(displaySpan.start)
                / duration
        } else {
            blockStart = Double(block.start)
            blockEnd = blockStart + Double(block.length)
        }
        let overlapStart = max(blockStart, viewport.start)
        let overlapEnd = min(blockEnd, viewport.end)
        guard overlapStart < overlapEnd else { return nil }

        let startFraction =
            (overlapStart - viewport.start) / viewport.length
        let endFraction =
            (overlapEnd - viewport.start) / viewport.length
        let naturalWidth =
            width * CGFloat(endFraction - startFraction)
        return TimelineBlockSlice(
            centerX:
                width * CGFloat((startFraction + endFraction) / 2),
            width: max(block.minimumWidth, naturalWidth)
        )
    }
}

private struct TimelineBar: View {
    let block: TimelineBlock
    let color: Color
    let actualColor: Color
    let width: CGFloat
    let isEditing: Bool
    let visibleDuration: TimeInterval
    let secondsPerPoint: TimeInterval
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onResizeStart: (TimeInterval) -> Void
    let onResizeEnd: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(primaryText)
                .font(.taption(size: block.height <= 20 ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(
                    block.isActual
                        ? Color.white
                        : Color.tpInk.opacity(0.64)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if !showsMinuteDetails, let count = block.groupCount {
                Spacer(minLength: 1)
                Text("▸ \(count)")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.62))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.70), in: Capsule())
            }
            if !showsMinuteDetails, block.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(actualColor)
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width,
            height: block.height,
            alignment: .leading
        )
        .background {
            if block.isGoal {
                GoalStripeBackground(
                    tint: color.opacity(0.76)
                )
            } else if block.isFixed {
                if block.isActual {
                    actualColor.opacity(0.82)
                } else {
                    FixedStripeBackground()
                }
            } else {
                color
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: blockCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            if block.isFixed {
                RoundedRectangle(
                    cornerRadius: blockCornerRadius,
                    style: .continuous
                )
                    .stroke(
                        block.isActual
                            ? actualColor
                            : Color(
                                red: 0.78,
                                green: 0.78,
                                blue: 0.80
                            ),
                        lineWidth: 1
                    )
            } else if block.isGoal {
                RoundedRectangle(
                    cornerRadius: blockCornerRadius,
                    style: .continuous
                )
                    .stroke(
                        color,
                        lineWidth: 1.1
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let fraction = block.actualFraction, fraction > 0 {
                Capsule()
                    .fill(actualColor)
                    .frame(
                        width: max(4, width * CGFloat(fraction)),
                        height: 3
                    )
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
        }
        .overlay {
            if isEditing, block.planID != nil, !block.isFixed {
                HStack {
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeStart(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                    Spacer()
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeEnd(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                }
                .padding(.horizontal, -5)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        onDoubleTap()
                    case .second:
                        onTap()
                    }
                }
        )
        .onLongPressGesture(
            minimumDuration: 0.18,
            maximumDistance: 12,
            perform: {
                guard !block.isFixed else { return }
                onEdit()
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded {
                    guard isEditing,
                          block.planID != nil,
                          !block.isFixed else { return }
                    onMove($0.translation.width * secondsPerPoint)
                }
        )
        .accessibilityHint(
            block.isFixed
                ? "자동 기록은 수정할 수 없습니다. 두 번 탭하면 해당 시간으로 확대합니다"
                : "두 번 탭하면 확대하고, 길게 누른 뒤 드래그하면 이동하며 양 끝점을 끌면 길이를 조절합니다"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onTap()
        }
    }

    private var showsMinuteDetails: Bool {
        visibleDuration
            <= GanttZoomStage.oneMinute.duration * 1.15
    }

    private var blockCornerRadius: CGFloat {
        block.isGoal ? 0 : (block.height <= 20 ? 10 : 7)
    }

    private var primaryText: String {
        GanttPrecisionPresentation.label(
            title: block.title,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            detailText: block.detailText,
            visibleDuration: visibleDuration
        )
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().stroke(Color.tpInk.opacity(0.65), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 2)
    }
}

private struct TimelineRowModel: Identifiable {
    let id: String
    let title: String
    let category: PlanCategory?
    let categoryID: String?
    let dotColor: Color
    let iconName: String?
    let customFillColor: Color?
    let customActualColor: Color?
    let isSystemAutomatic: Bool
    let height: CGFloat
    let blocks: [TimelineBlock]

    init(
        title: String,
        id: String? = nil,
        category: PlanCategory? = nil,
        categoryID: String? = nil,
        dotColor: Color? = nil,
        systemImage: String? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        isSystemAutomatic: Bool = false,
        height: CGFloat = 60,
        blocks: [TimelineBlock]
    ) {
        self.id = id ?? categoryID ?? title
        self.title = title
        self.category = category
        self.categoryID = categoryID
        self.dotColor = dotColor ?? category?.darkColor ?? .clear
        self.iconName = systemImage
        self.customFillColor = fillColor
        self.customActualColor = actualColor
        self.isSystemAutomatic = isSystemAutomatic
        self.height = height
        self.blocks = blocks
    }

    var fillColor: Color {
        customFillColor
            ?? category?.color
            ?? Color(red: 0.94, green: 0.94, blue: 0.95)
    }

    var actualColor: Color {
        customActualColor
            ?? category?.darkColor
            ?? Color.tpSecondary
    }
}

private struct TimelineBlock: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let isGoal: Bool
    let start: CGFloat
    let length: CGFloat
    let top: CGFloat
    let height: CGFloat
    let isFixed: Bool
    let groupCount: Int?
    let actualFraction: Double?
    let status: PlanStatus
    let isActual: Bool
    let opensLocationTimeline: Bool
    let minimumWidth: CGFloat
    let startsAt: Date?
    let endsAt: Date?
    let detailText: String?
    let categoryID: String?
    let categoryName: String?

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        start: CGFloat,
        length: CGFloat,
        top: CGFloat = 16,
        height: CGFloat = 26,
        isFixed: Bool = false,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        minimumWidth: CGFloat = 18,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        detailText: String? = nil,
        categoryID: String? = nil,
        categoryName: String? = nil,
        isGoal: Bool = false
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.isGoal = isGoal
        self.start = start
        self.length = length
        self.top = top
        self.height = height
        self.isFixed = isFixed
        self.groupCount = groupCount
        self.actualFraction = actualFraction
        self.status = status
        self.isActual = isActual
        self.opensLocationTimeline = opensLocationTimeline
        self.minimumWidth = minimumWidth
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.detailText = detailText
        self.categoryID = categoryID
        self.categoryName = categoryName
    }
}

private struct SummaryColor {
    let color: Color
    let opacity: Double

    init(_ color: Color, _ opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}

private struct PhotoAssetThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.tpPhoto, .tpPhotoDark.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "photo")
                        .font(.taption(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 120, height: 120)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}

#Preview {
    ScheduleView(model: AppModel())
}
