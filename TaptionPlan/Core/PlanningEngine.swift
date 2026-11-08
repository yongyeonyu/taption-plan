import Foundation
import TaptionPlanCore

/// High-frequency timeline gestures may arrive faster than the display can
/// present them. Keep the latest sample for the gesture end, but only publish
/// intermediate state at the display cadence.
typealias TimelineInteractionFrameGate = TaptionInputFrameGate

/// Keeps a timeline editor's latest gesture projection separate from the
/// presentation projection. Input can arrive at 240Hz; SwiftUI receives at
/// most the display-budgeted projections, plus the final gesture state.
final class TimelineNLEProjection<State: Equatable & Sendable> {
    private var projection = TaptionLatestValueProjection<State>()
    var latestState: State? { projection.latestValue }
    var renderedState: State? { projection.renderedValue }

    func begin(with state: State) { projection.begin(with: state) }
    func synchronize(with state: State) { projection.synchronize(with: state) }

    func submit(_ state: State, nowUptime: TimeInterval, force: Bool = false) -> State? {
        projection.submit(state, at: nowUptime, isFinal: force)
    }

    func finish(with state: State, nowUptime: TimeInterval) -> State? {
        projection.submit(state, at: nowUptime, isFinal: true)
    }

    func reset() { projection.reset() }
}

struct MapHomeTimeSidebarNLEState: Equatable, Sendable {
    var selectedMinute: Int
    var visibleStartMinute: Int
    var visibleDurationMinutes: Int
}

/// Integration reads are much more expensive than a timeline frame. A tab
/// selection, foreground callback and sensor callback can all arrive for the
/// same document window, so keep one short-lived admission gate in front of
/// HealthKit, Screen Time and location enumeration.
struct TimelineIntegrationRefreshGate {
    static let minimumRepeatInterval: TimeInterval = 5

    private(set) var lastKey: String?
    private(set) var lastUptime: TimeInterval?

    mutating func shouldStart(
        key: String,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> Bool {
        guard !force,
              let lastKey,
              let lastUptime,
              lastKey == key,
              nowUptime - lastUptime < Self.minimumRepeatInterval else {
            return true
        }
        return false
    }

    mutating func commit(key: String, nowUptime: TimeInterval) {
        lastKey = key
        lastUptime = nowUptime
    }
}

/// Cached timeline rows keep blocks ordered by start time. This index narrows
/// every drag frame to blocks that can intersect the visible window instead
/// of rescanning a month or year of off-screen records.
enum TimelineVisibleIntervalIndex {
    static func prefixMaximumEnds(
        starts: [Double],
        lengths: [Double]
    ) -> [Double] {
        guard starts.count == lengths.count else { return [] }
        var maximum = -Double.infinity
        return zip(starts, lengths).map { start, length in
            maximum = max(maximum, start + max(0, length))
            return maximum
        }
    }

    static func candidateRange(
        starts: [Double],
        prefixMaximumEnds: [Double],
        visibleStart: Double,
        visibleEnd: Double
    ) -> Range<Int> {
        guard starts.count == prefixMaximumEnds.count,
              visibleStart < visibleEnd,
              !starts.isEmpty else {
            return 0..<0
        }

        var lower = 0
        var upper = prefixMaximumEnds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if prefixMaximumEnds[middle] > visibleStart {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let firstCandidate = lower

        lower = firstCandidate
        upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] >= visibleEnd {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return firstCandidate..<max(firstCandidate, lower)
    }
}

enum PlanHierarchy {
    static func children(
        of parentID: UUID,
        in plans: [PlanRecord]
    ) -> [PlanRecord] {
        plans
            .filter { $0.parentID == parentID }
            .sorted { $0.span.start < $1.span.start }
    }

    static func descendants(
        of parentID: UUID,
        in plans: [PlanRecord]
    ) throws -> [PlanRecord] {
        let byParent = Dictionary(grouping: plans.compactMap { plan in
            plan.parentID.map { ($0, plan) }
        }, by: \.0)
        var result: [PlanRecord] = []
        var visiting = Set<UUID>()
        var visited = Set<UUID>()

        func visit(_ id: UUID) throws {
            guard !visiting.contains(id) else {
                throw PlanningError.parentCycle
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for pair in byParent[id, default: []] {
                result.append(pair.1)
                try visit(pair.1.id)
            }
            visiting.remove(id)
            visited.insert(id)
        }

        try visit(parentID)
        return result
    }

    static func validate(_ plans: [PlanRecord]) throws {
        let ids = Set(plans.map(\.id))
        for plan in plans {
            if let parentID = plan.parentID, !ids.contains(parentID) {
                throw PlanningError.missingPlan(parentID)
            }
            _ = try descendants(of: plan.id, in: plans)
        }
    }

    static func attach(
        child: PlanRecord,
        to parentID: UUID,
        in plans: [PlanRecord]
    ) throws -> PlanRecord {
        guard let parent = plans.first(where: { $0.id == parentID }) else {
            throw PlanningError.missingPlan(parentID)
        }
        guard child.id != parentID else {
            throw PlanningError.parentCycle
        }
        let parentDescendants = try descendants(of: child.id, in: plans)
        guard !parentDescendants.contains(where: { $0.id == parentID }) else {
            throw PlanningError.parentCycle
        }
        guard parent.span.start <= child.span.start,
              child.span.end <= parent.span.end else {
            throw PlanningError.childOutsideParent
        }
        var value = child
        value.parentID = parentID
        value.updatedAt = .now
        return value
    }
}

enum GoalDecompositionEngine {
    static func makeChild(
        parent: PlanRecord,
        title: String,
        span: TimeSpan,
        categoryID: String? = nil
    ) throws -> PlanRecord {
        guard parent.span.start <= span.start, span.end <= parent.span.end else {
            throw PlanningError.childOutsideParent
        }
        return PlanRecord(
            title: title,
            span: span,
            categoryID: categoryID ?? parent.categoryID,
            parentID: parent.id
        )
    }
}

struct TimelineLaneAllocation<ID: Hashable> {
    var lanes: [ID: Int]
    var count: Int
}

/// Keeps raw stays intact while showing one block for duplicate place results.
enum PlaceStayPresentationEngine {
    static func consolidated(_ stays: [PlaceStay]) -> [PlaceStay] {
        let samePlaceValues = mergeSamePlaceDuplicates(stays)
        var result: [PlaceStay] = []
        for stay in samePlaceValues {
            let overlappingIndices = result.indices.filter {
                result[$0].span.intersection(with: stay.span) != nil
            }
            guard !overlappingIndices.isEmpty else {
                result.append(stay)
                continue
            }

            // 위치 센서는 같은 시간에 서로 다른 장소 후보를 만들 수 있다.
            // 표시에서는 가장 신뢰할 수 있는 후보 하나만 남기되 원본 기록은
            // 건드리지 않는다. 새 후보가 기존 후보 모두보다 정확할 때만
            // 교체하므로 결과에는 겹치는 위치 막대가 생기지 않는다.
            guard overlappingIndices.allSatisfy({
                isPreferred(stay, over: result[$0])
            }) else {
                continue
            }
            for index in overlappingIndices.reversed() {
                result.remove(at: index)
            }
            result.append(stay)
        }
        return result.sorted(by: chronological)
    }

    private static func mergeSamePlaceDuplicates(
        _ stays: [PlaceStay]
    ) -> [PlaceStay] {
        var result: [PlaceStay] = []
        for stay in stays.sorted(by: chronological) {
            var value = stay
            for index in result.indices.reversed()
            where overlapsSamePlace(result[index], value) {
                value = merged(result.remove(at: index), value)
            }
            result.append(value)
        }
        return result.sorted(by: chronological)
    }

    private static func overlapsSamePlace(
        _ lhs: PlaceStay,
        _ rhs: PlaceStay
    ) -> Bool {
        let samePlace = (!lhs.placeKey.isEmpty && lhs.placeKey == rhs.placeKey)
            || normalized(lhs.displayName) == normalized(rhs.displayName)
        let sameFloor = lhs.floor == rhs.floor
            || lhs.floor == nil
            || rhs.floor == nil
        return samePlace && sameFloor
            && lhs.span.intersection(with: rhs.span) != nil
    }

    private static func merged(
        _ lhs: PlaceStay,
        _ rhs: PlaceStay
    ) -> PlaceStay {
        let preferred = isPreferred(rhs, over: lhs) ? rhs : lhs
        let fallback = preferred.id == lhs.id ? rhs : lhs
        var value = preferred
        value.span = TimeSpan(
            start: min(lhs.span.start, rhs.span.start),
            end: max(lhs.span.end, rhs.span.end)
        )
        value.confidence = confidenceRank(lhs.confidence)
            >= confidenceRank(rhs.confidence) ? lhs.confidence : rhs.confidence
        value.isConfirmed = lhs.isConfirmed || rhs.isConfirmed
        value.buildingName = value.buildingName ?? fallback.buildingName
        value.floor = value.floor ?? fallback.floor
        value.floorEvidence = value.floorEvidence ?? fallback.floorEvidence
        value.point = value.point ?? fallback.point
        return value
    }

    private static func isPreferred(
        _ lhs: PlaceStay,
        over rhs: PlaceStay
    ) -> Bool {
        let leftScore = score(lhs)
        let rightScore = score(rhs)
        if leftScore != rightScore { return leftScore > rightScore }
        let leftHorizontalAccuracy = validAccuracy(
            lhs.point?.horizontalAccuracy
        )
        let rightHorizontalAccuracy = validAccuracy(
            rhs.point?.horizontalAccuracy
        )
        if leftHorizontalAccuracy != rightHorizontalAccuracy {
            return leftHorizontalAccuracy < rightHorizontalAccuracy
        }
        let leftVerticalAccuracy = validAccuracy(lhs.point?.verticalAccuracy)
        let rightVerticalAccuracy = validAccuracy(rhs.point?.verticalAccuracy)
        if leftVerticalAccuracy != rightVerticalAccuracy {
            return leftVerticalAccuracy < rightVerticalAccuracy
        }
        if lhs.span.duration != rhs.span.duration {
            return lhs.span.duration > rhs.span.duration
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func score(_ stay: PlaceStay) -> Int {
        (stay.isConfirmed ? 32 : 0)
            + confidenceRank(stay.confidence) * 8
            + (
                validAccuracy(stay.point?.horizontalAccuracy).isFinite
                    ? 4
                    : 0
            )
            + (stay.floorEvidence == nil ? 0 : 2)
            + (stay.floor == nil ? 0 : 1)
    }

    private static func validAccuracy(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else {
            return .infinity
        }
        return value
    }

    private static func confidenceRank(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func chronological(_ lhs: PlaceStay, _ rhs: PlaceStay) -> Bool {
        lhs.span.start == rhs.span.start
            ? lhs.span.end < rhs.span.end
            : lhs.span.start < rhs.span.start
    }
}

/// HealthKit sleep sessions are authoritative for the time they cover.  The
/// motion/location records that were previously classified as generic
/// activity are derived display records, so they can be trimmed without
/// changing the archived sensor stream.
enum SleepActualReconciliationEngine {
    static let modelVersion = "healthkit-sleep-reconciled-v1"

    static func coveredAutomaticIDs(
        in actuals: [ActualRecord],
        by sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date = .now
    ) -> Set<UUID> {
        let sleepSpans = sleepSpans(
            sessions,
            inside: span,
            asOf: date
        )
        guard !sleepSpans.isEmpty else { return [] }
        return Set(actuals.compactMap { actual in
            guard shouldTrim(actual),
                  let overlap = sleepOverlap(
                      actual.span(asOf: date),
                      with: sleepSpans
                  ),
                  overlap.duration > 0 else {
                return nil
            }
            return actual.id
        })
    }

    static func applying(
        _ actuals: [ActualRecord],
        sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let spans = sleepSpans(sessions, inside: span, asOf: date)
        guard !spans.isEmpty else { return actuals }

        var result: [ActualRecord] = []
        var authoritativeIDs = Set<UUID>()
        for actual in actuals {
            let actualSpan = actual.span(asOf: date)
            guard sleepOverlap(actualSpan, with: spans) != nil else {
                result.append(actual)
                continue
            }

            if isAuthoritativeSleep(actual) {
                var normalized = actual
                normalized.title = "수면"
                normalized.categoryID = "sleep"
                if sessions.contains(where: {
                    $0.isAppleWatchConfirmed
                        && $0.span.intersection(with: actualSpan) != nil
                }) {
                    normalized.source = .appleWatch
                }
                normalized.behavior = WatchBehaviorKind.sleep.rawValue
                normalized.evidence = Array(
                    Set(actual.evidence + ["HealthKit 수면 기록"])
                ).sorted()
                normalized.modelVersion = Self.modelVersion
                result.append(normalized)
                authoritativeIDs.insert(actual.id)
                continue
            }

            guard shouldTrim(actual) else {
                result.append(actual)
                continue
            }

            let remainders = ActualIntervalMergeEngine.subtracting(
                spans,
                from: actualSpan
            )
            for (offset, remainder) in remainders.enumerated() {
                var value = actual
                value.id = offset == 0
                    ? actual.id
                    : remainderID(of: actual.id, offset: offset)
                value.startedAt = remainder.start
                value.endedAt = remainder.end
                result.append(value)
            }
        }

        for session in sessions {
            guard let visible = session.span.intersection(with: span),
                  visible.start < min(visible.end, date),
                  !actuals.contains(where: { actual in
                      isAuthoritativeSleep(actual)
                          && actual.span(asOf: date).intersection(
                              with: visible
                          )?.duration ?? 0 > 0
                  }) else {
                continue
            }
            let end = min(visible.end, date)
            guard end > visible.start,
                  !authoritativeIDs.contains(session.id) else { continue }
            result.append(
                ActualRecord(
                    id: session.id,
                    planID: nil,
                    title: "수면",
                    categoryID: "sleep",
                    startedAt: visible.start,
                    endedAt: end,
                    source: session.isAppleWatchConfirmed
                        ? .appleWatch
                        : .healthKit,
                    confidence: .high,
                    createdAt: visible.start,
                    behavior: WatchBehaviorKind.sleep.rawValue,
                    evidence: ["HealthKit 수면 기록"],
                    modelVersion: Self.modelVersion
                )
            )
        }
        return AppleWatchNapPolicy.labeling(PhoneSleepFusion.droppingCovered(result, by: sessions, inside: span, asOf: date).sorted { $0.startedAt < $1.startedAt }, sessions: sessions, inside: span)
    }

    private static func sleepSpans(
        _ sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date
    ) -> [TimeSpan] {
        sessions.compactMap { session in
            guard let clipped = session.span.intersection(with: span) else {
                return nil
            }
            let end = min(clipped.end, date)
            guard end > clipped.start else { return nil }
            return TimeSpan(start: clipped.start, end: end)
        }
    }

    private static func sleepOverlap(
        _ actual: TimeSpan,
        with spans: [TimeSpan]
    ) -> TimeSpan? {
        let pieces = spans.compactMap { actual.intersection(with: $0) }
        guard let first = pieces.first else { return nil }
        let merged = ActualIntervalMergeEngine.union(pieces, mergeGap: 0)
        return merged.count == 1
            ? merged[0]
            : TimeSpan(start: first.start, end: merged.last?.end ?? first.end)
    }

    private static func isAuthoritativeSleep(_ actual: ActualRecord) -> Bool {
        (actual.source == .healthKit || actual.source == .appleWatch)
            && AutomaticRecordTimelineEngine.isSleep(actual)
    }

    private static func shouldTrim(_ actual: ActualRecord) -> Bool {
        guard actual.source == .motion || actual.source == .location else {
            return false
        }
        guard actual.categoryID != "appUsage",
              actual.categoryID != "exercise",
              !AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) else {
            return false
        }
        // 자동 이동(지하철 추정·빈칸 추정)도 수면 시간에서는 잘린다(CAT1029A01).
        return actual.categoryID == "activity" || actual.categoryID == "movement"
            || actual.categoryID == "rest"
            || actual.categoryID == "routine"
            || actual.behavior == "stationary"
            || actual.behavior == "homeRest"
            || actual.behavior == "cafe"
            || actual.behavior == "housework"
    }

    private static func remainderID(of id: UUID, offset: Int) -> UUID {
        StableRecordID.remainder(of: id, offset: offset)
    }
}

enum TimelineLaneAllocator {
    static func allocate<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> TimelineLaneAllocation<Item.ID>
    where Item.ID: Hashable {
        let sorted = items.sorted {
            let lhs = span($0)
            let rhs = span($1)
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        var laneEnds: [Date] = []
        var lanes: [Item.ID: Int] = [:]

        for item in sorted {
            let itemSpan = span(item)
            let lane = laneEnds.firstIndex {
                $0 <= itemSpan.start
            } ?? laneEnds.count

            if lane == laneEnds.count {
                laneEnds.append(itemSpan.end)
            } else {
                laneEnds[lane] = itemSpan.end
            }
            lanes[item.id] = lane
        }

        return TimelineLaneAllocation(
            lanes: lanes,
            count: laneEnds.count
        )
    }
}

struct TimelineAggregationEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = Self.normalizedTimelineCalendar(calendar)
    }

    private static func normalizedTimelineCalendar(_ calendar: Calendar) -> Calendar {
        var timelineCalendar = calendar
        timelineCalendar.locale = Locale(identifier: "ko_KR")
        timelineCalendar.firstWeekday = 2  // Monday
        timelineCalendar.minimumDaysInFirstWeek = 4
        return timelineCalendar
    }

    func rollup(
        goalID: UUID,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        asOf: Date = .now
    ) throws -> GoalRollup {
        guard let goal = plans.first(where: { $0.id == goalID }) else {
            throw PlanningError.missingPlan(goalID)
        }
        let descendants = try PlanHierarchy.descendants(of: goalID, in: plans)
        let scopedPlans = descendants.isEmpty ? [goal] : descendants
        let goalMatches = GoalActivityMatchingEngine.matches(
            goal: goal,
            plans: plans,
            actuals: actuals,
            asOf: asOf
        )

        let plannedByCategory = accumulate(
            scopedPlans.map { ($0.categoryID, $0.span) },
            inside: goal.span
        )
        let actualByCategory = accumulate(
            goalMatches
                .map(\.actual)
                .map { ($0.categoryID, $0.span(asOf: asOf)) },
            inside: goal.span
        )

        return GoalRollup(
            goalID: goalID,
            descendantCount: descendants.count,
            plannedDuration: mergedDuration(
                scopedPlans.map(\.span),
                inside: goal.span
            ),
            actualDuration: mergedDuration(
                goalMatches.map { $0.actual.span(asOf: asOf) },
                inside: goal.span
            ),
            categories: mergeDurations(
                planned: plannedByCategory,
                actual: actualByCategory
            )
        )
    }

    func buckets(
        of unit: TimelineLevel,
        inside outerSpan: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> [SummaryBucket] {
        let bucketSpans = intervals(of: unit, inside: outerSpan)
        guard !bucketSpans.isEmpty else { return [] }

        // 칸마다 기록 전체를 다시 훑으면 칸 수 × 기록 수만큼 일한다.  기록을
        // 한 번만 훑어 겹치는 칸에만 나눠 담는다.
        let planned = distribute(
            plans.map { ($0.categoryID, $0.span) },
            over: bucketSpans
        )
        let actual = distribute(
            actuals.map { ($0.categoryID, $0.span(asOf: asOf)) },
            over: bucketSpans
        )
        var photoCounts = [Int](repeating: 0, count: bucketSpans.count)
        var representatives = [(Date, String)?](
            repeating: nil,
            count: bucketSpans.count
        )
        for photo in photos where !photo.isHiddenFromTimeline {
            guard let index = bucketIndex(
                containing: photo.capturedAt,
                in: bucketSpans
            ) else { continue }
            photoCounts[index] += 1
            if let current = representatives[index],
               current.0 <= photo.capturedAt {
                continue
            }
            representatives[index] = (photo.capturedAt, photo.id)
        }

        return bucketSpans.enumerated().map { index, bucketSpan in
            SummaryBucket(
                id: "\(unit.rawValue)-\(bucketSpan.start.timeIntervalSince1970)",
                span: bucketSpan,
                categories: mergeDurations(
                    planned: planned[index],
                    actual: actual[index]
                ),
                photoCount: photoCounts[index],
                representativePhotoID: representatives[index]?.1
            )
        }
    }

    /// 구간 하나를 통째로 요약한다. 배율이 정한 칸이 아니라 사용자가 고른
    /// 칸의 합집합처럼 달력 경계와 어긋난 구간도 같은 규칙으로 잰다.
    func summary(
        of span: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> SummaryBucket {
        let planned = distribute(
            plans.map { ($0.categoryID, $0.span) },
            over: [span]
        )
        let actual = distribute(
            actuals.map { ($0.categoryID, $0.span(asOf: asOf)) },
            over: [span]
        )
        let visiblePhotos = photos.filter {
            !$0.isHiddenFromTimeline && span.contains($0.capturedAt)
        }
        return SummaryBucket(
            id: "span-\(span.start.timeIntervalSince1970)",
            span: span,
            categories: mergeDurations(
                planned: planned[0],
                actual: actual[0]
            ),
            photoCount: visiblePhotos.count,
            representativePhotoID: visiblePhotos
                .min { $0.capturedAt < $1.capturedAt }?
                .id
        )
    }

    private func distribute(
        _ entries: [(String, TimeSpan)],
        over buckets: [TimeSpan]
    ) -> [[String: TimeInterval]] {
        var spansByBucket = [[String: [TimeSpan]]](
            repeating: [:],
            count: buckets.count
        )
        var categoryIDs: Set<String> = []
        for (categoryID, span) in entries {
            categoryIDs.insert(categoryID)
            var index = firstBucketIndex(endingAfter: span.start, in: buckets)
            while index < buckets.count, buckets[index].start < span.end {
                if let clipped = span.intersection(with: buckets[index]) {
                    spansByBucket[index][categoryID, default: []]
                        .append(clipped)
                }
                index += 1
            }
        }
        // 원래 계산은 어느 칸에도 걸치지 않은 분류도 0으로 남겼다.  요약 띠의
        // 색과 정렬이 그 빈 항목까지 보므로 같은 열쇠 집합을 유지한다.
        return spansByBucket.enumerated().map { index, grouped in
            var value = [String: TimeInterval](
                minimumCapacity: categoryIDs.count
            )
            for categoryID in categoryIDs {
                value[categoryID] = mergedDuration(
                    grouped[categoryID] ?? [],
                    inside: buckets[index]
                )
            }
            return value
        }
    }

    private func firstBucketIndex(
        endingAfter date: Date,
        in buckets: [TimeSpan]
    ) -> Int {
        var low = 0
        var high = buckets.count
        while low < high {
            let middle = (low + high) / 2
            if buckets[middle].end <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func bucketIndex(
        containing date: Date,
        in buckets: [TimeSpan]
    ) -> Int? {
        let index = firstBucketIndex(endingAfter: date, in: buckets)
        guard index < buckets.count,
              buckets[index].contains(date) else { return nil }
        return index
    }

    func interval(
        for level: TimelineLevel,
        containing date: Date
    ) -> TimeSpan {
        let component: Calendar.Component
        switch level {
        case .day:
            component = .day
        case .week:
            component = .weekOfYear
        case .month:
            component = .month
        case .year:
            component = .year
        }
        let interval = calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return TimeSpan(start: interval.start, end: interval.end)
    }

    private func intervals(
        of level: TimelineLevel,
        inside outer: TimeSpan
    ) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var cursor = outer.start
        let component: Calendar.Component
        switch level {
        case .day:
            component = .day
        case .week:
            component = .weekOfYear
        case .month:
            component = .month
        case .year:
            component = .year
        }

        while cursor < outer.end {
            guard let interval = calendar.dateInterval(of: component, for: cursor) else {
                break
            }
            let span = TimeSpan(
                start: max(interval.start, outer.start),
                end: min(interval.end, outer.end)
            )
            if span.duration > 0 {
                result.append(span)
            }
            guard interval.end > cursor else { break }
            cursor = interval.end.addingTimeInterval(0.001)
        }
        return result
    }

    private func accumulate(
        _ entries: [(String, TimeSpan)],
        inside bucket: TimeSpan
    ) -> [String: TimeInterval] {
        let grouped = Dictionary(grouping: entries, by: \.0)
        return grouped.reduce(into: [:]) { partial, pair in
            partial[pair.key] = mergedDuration(
                pair.value.map(\.1),
                inside: bucket
            )
        }
    }

    private func mergedDuration(
        _ spans: [TimeSpan],
        inside bucket: TimeSpan
    ) -> TimeInterval {
        let ordered = spans
            .compactMap { $0.intersection(with: bucket) }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    private func mergeDurations(
        planned: [String: TimeInterval],
        actual: [String: TimeInterval]
    ) -> [CategoryDuration] {
        let keys = Set(planned.keys).union(actual.keys)
        return keys
            .map {
                CategoryDuration(
                    categoryID: $0,
                    planned: planned[$0, default: 0],
                    actual: actual[$0, default: 0]
                )
            }
            .sorted {
                max($0.actual, $0.planned) > max($1.actual, $1.planned)
            }
    }
}

struct TimelinePeriodNavigationEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func adjacentDate(
        from date: Date,
        level: TimelineLevel,
        direction: Int
    ) -> Date? {
        guard direction != 0 else { return date }
        return calendar.date(
            byAdding: component(for: level),
            value: direction > 0 ? 1 : -1,
            to: date
        )
    }

    func canNavigate(
        from date: Date,
        level: TimelineLevel,
        direction: Int,
        snapshot: TaptionDataSnapshot,
        asOf: Date = .now
    ) -> Bool {
        // 기록이 없는 날짜도 고를 수 있어야 한다. 계획을 세우려면 아직
        // 아무것도 없는 앞날로 넘어가야 하고, 빈 날이라는 사실 자체도
        // 확인할 수 있어야 한다. 달력이 날짜를 만들어 주는지만 본다.
        guard direction != 0 else { return false }
        return adjacentDate(
            from: date,
            level: level,
            direction: direction
        ) != nil
    }

    private func component(
        for level: TimelineLevel
    ) -> Calendar.Component {
        switch level {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

enum ActionMemoEditingEngine {
    static func updating(
        _ memo: ActionMemo,
        text: String,
        kind: MemoKind,
        at date: Date = .now
    ) -> ActionMemo? {
        let cleanText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanText.isEmpty else { return nil }
        var value = memo
        value.text = cleanText
        value.kind = kind
        value.updatedAt = date
        return value
    }
}

enum MapMemoDisplayFilterEngine {
    static func visibleMemos(
        _ memos: [ActionMemo],
        filter: MapMemoDisplayFilter,
        selectedPlanIDs: Set<UUID>,
        selectedTargetIDs: Set<String>
    ) -> [ActionMemo] {
        let mapped = memos.filter { $0.mapPoint != nil }
        guard filter == .relevant else { return mapped }

        return mapped.filter { memo in
            if let planID = memo.planID, selectedPlanIDs.contains(planID) {
                return true
            }
            if let targetID = memo.targetID,
               selectedTargetIDs.contains(targetID) {
                return true
            }
            return false
        }
    }

    static func visibleMemos(
        _ memos: [ActionMemo],
        on date: Date,
        filter: MapMemoDisplayFilter,
        selectedPlanIDs: Set<UUID>,
        selectedTargetIDs: Set<String>,
        calendar: Calendar = .autoupdatingCurrent,
        through: Date? = nil
    ) -> [ActionMemo] {
        visibleMemos(
            memos,
            filter: filter,
            selectedPlanIDs: selectedPlanIDs,
            selectedTargetIDs: selectedTargetIDs
        ).filter {
            guard calendar.isDate($0.occurredAt, inSameDayAs: date) else {
                return false
            }
            guard let through else { return true }
            return $0.occurredAt <= through
        }
    }
}

enum MapMemoLinkEngine {
    static func plan(
        containing date: Date,
        in plans: [PlanRecord]
    ) -> PlanRecord? {
        plans
            .filter { $0.span.start <= date && date < $0.span.end }
            .sorted {
                if $0.span.duration != $1.span.duration {
                    return $0.span.duration < $1.span.duration
                }
                return $0.createdAt < $1.createdAt
            }
            .first
    }
}

enum MapStickerDisplayFilterEngine {
    static func visibleMapStickers(
        _ stickers: [MapSticker],
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapSticker] {
        stickers.filter {
            $0.placement == .map
                && $0.point != nil
                && calendar.isDate($0.occurredAt, inSameDayAs: date)
        }
    }
}

/// A memo used to need a host plan, so a note left on a category row created a
/// one-minute placeholder titled `메모 - <카테고리>`. Those placeholders then
/// showed up in the 기록 탭 계획 카드 as plans the user never made. This lifts
/// their notes into standalone memos and removes only the placeholders.
enum MemoShellPlanMigration {
    static let titlePrefix = "메모 - "
    private static let shellDuration: TimeInterval = 60

    /// Deliberately strict: every condition is something the placeholder
    /// factory always produced. A plan that fails even one of them is a plan
    /// the user could have made by hand, so it is left alone.
    static func isShell(
        _ plan: PlanRecord,
        actuals: [ActualRecord],
        recordLinks: [RecordLink]
    ) -> Bool {
        let referencedRecordIDs = Set(actuals.flatMap {
            [$0.planID, $0.routineID].compactMap { $0 }
        })
        let referencedNodeIDs = Set(recordLinks.flatMap {
            [$0.fromNodeID, $0.toNodeID]
        })
        return isShell(
            plan,
            referencedRecordIDs: referencedRecordIDs,
            referencedNodeIDs: referencedNodeIDs
        )
    }

    private static func isShell(
        _ plan: PlanRecord,
        referencedRecordIDs: Set<UUID>,
        referencedNodeIDs: Set<String>
    ) -> Bool {
        guard plan.title.hasPrefix(titlePrefix),
              plan.title.count > titlePrefix.count,
              abs(plan.span.duration - shellDuration) < 0.5,
              plan.parentID == nil,
              plan.status == .planned,
              plan.origin == .user,
              !plan.isFixed,
              !plan.isImportant,
              plan.middleCategoryName == nil,
              plan.subCategoryName == nil,
              plan.repeatRules == nil,
              plan.externalCalendarID == nil,
              plan.externalEventID == nil else {
            return false
        }
        // A placeholder was never started, completed or linked to anything.
        guard !referencedRecordIDs.contains(plan.id) else {
            return false
        }
        return !referencedNodeIDs.contains("action.\(plan.id.uuidString)")
            && !referencedNodeIDs.contains("routine.\(plan.id.uuidString)")
    }

    /// Idempotent: once the placeholders are gone a second run finds nothing.
    static func apply(to snapshot: inout TaptionDataSnapshot) {
        apply(to: &snapshot, cancellationCheck: {})
    }

    static func apply(
        to snapshot: inout TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        var referencedRecordIDs = Set<UUID>()
        referencedRecordIDs.reserveCapacity(snapshot.actuals.count)
        for (index, actual) in snapshot.actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if let planID = actual.planID {
                referencedRecordIDs.insert(planID)
            }
            if let routineID = actual.routineID {
                referencedRecordIDs.insert(routineID)
            }
        }

        try cancellationCheck()
        var referencedNodeIDs = Set<String>()
        referencedNodeIDs.reserveCapacity(snapshot.recordLinks.count * 2)
        for (index, link) in snapshot.recordLinks.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            referencedNodeIDs.insert(link.fromNodeID)
            referencedNodeIDs.insert(link.toNodeID)
        }

        try cancellationCheck()
        var shellsByID: [UUID: PlanRecord] = [:]
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard isShell(
                plan,
                referencedRecordIDs: referencedRecordIDs,
                referencedNodeIDs: referencedNodeIDs
            ) else { continue }
            shellsByID[plan.id] = plan
        }
        try cancellationCheck()
        guard !shellsByID.isEmpty else { return }

        try cancellationCheck()
        var memos = snapshot.memos
        for index in memos.indices {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let planID = memos[index].planID,
                  let shell = shellsByID[planID] else { continue }
            memos[index].planID = nil
            if memos[index].targetID == "plan.\(planID.uuidString)" {
                memos[index].targetID = nil
            }
            memos[index].categoryID = memos[index].categoryID
                ?? shell.categoryID
            memos[index].occurredAt = shell.span.start
        }

        try cancellationCheck()
        var plans: [PlanRecord] = []
        plans.reserveCapacity(snapshot.plans.count - shellsByID.count)
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if shellsByID[plan.id] == nil { plans.append(plan) }
        }

        try cancellationCheck()
        snapshot.memos = memos
        snapshot.plans = plans
    }
}

enum PhotoClusterer {
    static func cluster(
        _ photos: [PhotoMoment],
        threshold: TimeInterval = 20 * 60
    ) -> [PhotoCluster] {
        let visible = photos
            .filter { !$0.isHiddenFromTimeline }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard var first = visible.first else { return [] }
        var current = [first]
        var clusters: [PhotoCluster] = []

        func appendCluster(_ values: [PhotoMoment]) {
            guard let representative = values.first(where: \.isFavorite) ?? values.first else {
                return
            }
            clusters.append(
                PhotoCluster(
                    id: representative.id,
                    representative: representative,
                    photos: values
                )
            )
        }

        for photo in visible.dropFirst() {
            if photo.capturedAt.timeIntervalSince(first.capturedAt) <= threshold {
                current.append(photo)
            } else {
                appendCluster(current)
                current = [photo]
            }
            first = photo
        }
        appendCluster(current)
        return clusters
    }

    static func nearestCluster(
        to date: Date,
        in photos: [PhotoMoment],
        tolerance: TimeInterval,
        threshold: TimeInterval = 20 * 60
    ) -> PhotoCluster? {
        let searchRadius = max(0, tolerance) + max(0, threshold)
        let candidates = photos.filter {
            !$0.isHiddenFromTimeline
                && abs($0.capturedAt.timeIntervalSince(date)) <= searchRadius
        }
        return cluster(candidates, threshold: threshold)
            .filter { cluster in
                guard let start = cluster.photos.first?.capturedAt,
                      let end = cluster.photos.last?.capturedAt else {
                    return false
                }
                return start.addingTimeInterval(-tolerance) <= date
                    && date <= end.addingTimeInterval(tolerance)
            }
            .min {
                abs($0.capturedAt.timeIntervalSince(date))
                    < abs($1.capturedAt.timeIntervalSince(date))
            }
    }
}

struct ReviewEngine: Sendable {
    var aggregation: TimelineAggregationEngine

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.aggregation = TimelineAggregationEngine(calendar: calendar)
    }

    func report(
        for level: TimelineLevel,
        containing date: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        weather: [WeatherContext],
        photos: [PhotoMoment],
        memos: [ActionMemo],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> ReviewReport {
        report(
            over: [aggregation.interval(for: level, containing: date)],
            plans: plans,
            actuals: actuals,
            weather: weather,
            photos: photos,
            memos: memos,
            asOf: asOf,
            scope: scope
        )
    }

    /// 떨어져 있는 여러 칸을 한 번에 본다. 칸마다 잰 값을 더하므로 사이의
    /// 빈 시간은 어디에도 들어가지 않는다. 구간은 서로 겹치지 않는다고 본다.
    func report(
        over spans: [TimeSpan],
        plans: [PlanRecord],
        actuals: [ActualRecord],
        weather: [WeatherContext],
        photos: [PhotoMoment],
        memos: [ActionMemo],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> ReviewReport {
        let ordered = spans.sorted { $0.start < $1.start }
        guard let first = ordered.first, let last = ordered.last else {
            return ReviewReport(
                span: TimeSpan(start: asOf, end: asOf),
                plannedDuration: 0,
                actualDuration: 0,
                categories: [],
                unplannedActualDuration: 0,
                contexts: []
            )
        }
        let hull = TimeSpan(start: first.start, end: last.end)

        let scopedPlans: [PlanRecord]
        let scopedActuals: [ActualRecord]
        switch scope {
        case .legacy:
            scopedPlans = plans
            scopedActuals = actuals
        case .canonical:
            scopedPlans = plans.map { plan in
                var value = plan
                value.categoryID = RecordAnalysisCategoryNormalizer.categoryID(
                    for: plan.categoryID
                )
                return value
            }
            scopedActuals = actuals.map { actual in
                var value = actual
                value.categoryID = RecordAnalysisCategoryNormalizer.categoryID(
                    for: actual.categoryID,
                    title: actual.title,
                    behavior: actual.behavior
                )
                return value
            }
        }

        var planned: [String: TimeInterval] = [:]
        var actual: [String: TimeInterval] = [:]
        for span in ordered {
            let bucket = aggregation.summary(
                of: span,
                plans: scopedPlans,
                actuals: scopedActuals,
                photos: photos,
                asOf: asOf
            )
            for category in bucket.categories {
                planned[category.categoryID, default: 0] += category.planned
                actual[category.categoryID, default: 0] += category.actual
            }
        }
        let categories = Set(planned.keys).union(actual.keys)
            .map {
                CategoryDuration(
                    categoryID: $0,
                    planned: planned[$0, default: 0],
                    actual: actual[$0, default: 0]
                )
            }
            .sorted {
                max($0.actual, $0.planned) > max($1.actual, $1.planned)
            }

        let knownPlanIDs = Set(scopedPlans.map(\.id))
        let unplanned = scopedActuals.reduce(0) { partial, actual in
            if let planID = actual.planID, knownPlanIDs.contains(planID) {
                return partial
            }
            let measured = actual.span(asOf: asOf)
            return partial + ordered.reduce(0) {
                $0 + (measured.intersection(with: $1)?.duration ?? 0)
            }
        }

        func isSelected(_ date: Date) -> Bool {
            ordered.contains { $0.contains(date) }
        }

        var contexts: [ReviewContext] = weather
            .filter { isSelected($0.observedAt) }
            .map {
                let airQualityText = $0.airQuality.map {
                    " · 미세 \($0.overallGrade.displayName) (PM10 \(Int($0.pm10MicrogramsPerCubicMeter.rounded())) / PM2.5 \(Int($0.pm25MicrogramsPerCubicMeter.rounded())))"
                } ?? ""
                return ReviewContext(
                    id: "weather-\($0.id.uuidString)",
                    date: $0.observedAt,
                    symbolName: $0.symbolName,
                    text: "\($0.condition) · \(AppRegion.current.temperature(celsius: $0.temperatureCelsius))°\(airQualityText)",
                    linkedPlanID: nil
                )
            }

        let visiblePhotos = photos.filter {
            isSelected($0.capturedAt) && !$0.isHiddenFromTimeline
        }
        if let first = visiblePhotos.first {
            contexts.append(
                ReviewContext(
                    id: "photos-\(hull.start.timeIntervalSince1970)",
                    date: first.capturedAt,
                    symbolName: "photo",
                    text: "기억으로 남긴 사진 \(visiblePhotos.count)장",
                    linkedPlanID: first.linkedPlanID
                )
            )
        }

        // 메모가 놓이는 자리는 적은 시각이 아니라 그 메모가 말하는 시각이다.
        // 오늘 적은 지난 화요일 이야기는 지난 화요일에 남는다.
        contexts.append(contentsOf: memos
            .filter {
                $0.isHighlightedInReview && isSelected($0.occurredAt)
            }
            .map {
                ReviewContext(
                    id: "memo-\($0.id.uuidString)",
                    date: $0.occurredAt,
                    symbolName: "note.text",
                    text: $0.text,
                    linkedPlanID: $0.planID
                )
            })

        return ReviewReport(
            span: hull,
            plannedDuration: categories.reduce(0) { $0 + $1.planned },
            actualDuration: categories.reduce(0) { $0 + $1.actual },
            categories: categories,
            unplannedActualDuration: unplanned,
            contexts: contexts.sorted { $0.date < $1.date }
        )
    }
}

/// How an actual record was associated with a goal.
enum GoalActualMatchKind: String, Equatable, Hashable, Sendable {
    case linked
    case automatic

    var displayName: String {
        switch self {
        case .linked: "연결됨"
        case .automatic: "자동 근거"
        }
    }
}

struct GoalActualMatch: Identifiable, Equatable, Hashable, Sendable {
    let actual: ActualRecord
    let kind: GoalActualMatchKind
    let overlapDuration: TimeInterval
    let matchedPlanID: UUID?

    var id: UUID { actual.id }
}

/// Resolves explicit links first, then associates unlinked HealthKit/Watch
/// sleep and activity records with the best overlapping repeat segment.
enum GoalActivityMatchingEngine {
    static func matches(
        goal: PlanRecord,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        asOf: Date = .now
    ) -> [GoalActualMatch] {
        let descendants = (try? PlanHierarchy.descendants(
            of: goal.id,
            in: plans
        )) ?? []
        let scopedIDs = Set([goal.id] + descendants.map(\.id))
        var claimed = Set<UUID>()
        let explicit = actuals.compactMap { actual -> GoalActualMatch? in
            if AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual) {
                guard let routineID = actual.routineID,
                      scopedIDs.contains(routineID) else { return nil }
                claimed.insert(actual.id)
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: routineID
                )
            }

            if let planID = actual.planID {
                // A record explicitly attached elsewhere must not be copied
                // into another goal merely because its category/time match.
                guard scopedIDs.contains(planID) else { return nil }
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: planID
                )
            }

            if let routineID = actual.routineID,
               scopedIDs.contains(routineID) {
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: routineID
                )
            }

            return nil
        }
        let repeatSegments = descendants.filter {
            $0.origin == .repeatRule
                && $0.categoryID == goal.categoryID
        }
        let automatic = actuals.compactMap { actual -> GoalActualMatch? in
            guard !claimed.contains(actual.id),
                  actual.planID == nil,
                  actual.routineID == nil,
                  (actual.source == .healthKit
                      || actual.source == .appleWatch
                      || actual.source == .motion
                      || actual.source == .media
                      || actual.source == .call),
                  AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                      goal.categoryID
                  ) else { return nil }
            let actualSpan = actual.span(asOf: asOf)
            let best = repeatSegments.compactMap { segment -> (PlanRecord, TimeInterval)? in
                guard let overlap = actualSpan.intersection(with: segment.span) else {
                    return nil
                }
                return (segment, overlap.duration)
            }.max { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.span.start > rhs.0.span.start
                    : lhs.1 < rhs.1
            }
            guard let best else { return nil }
            return GoalActualMatch(
                actual: actual,
                kind: .automatic,
                overlapDuration: best.1,
                matchedPlanID: best.0.id
            )
        }
        return (explicit + automatic).sorted {
            if $0.actual.startedAt == $1.actual.startedAt {
                return $0.actual.id.uuidString < $1.actual.id.uuidString
            }
            return $0.actual.startedAt < $1.actual.startedAt
        }
    }

    static func progress(
        for plan: PlanRecord,
        matches: [GoalActualMatch],
        asOf: Date = .now
    ) -> Double {
        let spans = matches.compactMap { match -> TimeSpan? in
            let actual = match.actual
            if actual.planID == plan.id
                || actual.routineID == plan.id
                || match.matchedPlanID == plan.id {
                return actual.span(asOf: asOf).intersection(with: plan.span)
            }
            return nil
        }
        guard plan.span.duration > 0 else { return 0 }
        let covered = TimeSpan.unionDuration(spans)
        return min(1, max(0, covered / plan.span.duration))
    }
}

// MARK: - Automatic · routine · action record graph

enum RecordLayer: String, CaseIterable, Sendable {
    case automatic = "자동"
    case routine = "루틴"
    case action = "액션"
}

struct RecordGraphNode: Identifiable, Hashable, Sendable {
    let id: String
    let layer: RecordLayer
    let title: String
    let span: TimeSpan
    let categoryID: String?
}

struct RecordGraphEdge: Identifiable, Hashable, Sendable {
    let from: String
    let to: String
    var id: String { "\(from)->\(to)" }
}

struct RecordRelationshipGraph: Sendable {
    let nodes: [RecordGraphNode]
    let edges: [RecordGraphEdge]
    var isEmpty: Bool { nodes.isEmpty }
}

/// Keeps automatic evidence, a routine, and its concrete action as separate
/// nodes while exposing only explicit relationships. Time/category overlap is
/// deliberately not treated as a connection.
enum RecordRelationshipEngine {
    static func make(
        inside span: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        calendarEvents: [CalendarRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        recordLinks: [RecordLink] = [],
        focusNodeID: String? = nil
    ) -> RecordRelationshipGraph {
        var allNodes: [RecordGraphNode] = []
        var edges: [RecordGraphEdge] = []
        var nodeIDs = Set<String>()
        var edgeIDs = Set<String>()
        let plansByID = Dictionary(
            plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        allNodes.reserveCapacity(
            calendarEvents.count
                + places.count
                + travel.count
                + actuals.count
                + plans.count
        )

        func appendEdge(from: String, to: String) {
            let edge = RecordGraphEdge(from: from, to: to)
            guard edgeIDs.insert(edge.id).inserted else { return }
            edges.append(edge)
        }

        func append(_ node: RecordGraphNode, includeOutsideSpan: Bool = false) {
            guard includeOutsideSpan || node.span.intersection(with: span) != nil,
                  nodeIDs.insert(node.id).inserted else { return }
            allNodes.append(node)
        }

        for event in calendarEvents {
            append(RecordGraphNode(
                id: "automatic.calendar.\(event.id)",
                layer: .automatic,
                title: event.title,
                span: event.span,
                categoryID: "calendar"
            ))
        }
        for place in places {
            append(RecordGraphNode(
                id: "automatic.place.\(place.id.uuidString)",
                layer: .automatic,
                title: place.floor.map { "\(place.displayName) · \($0)층" } ?? place.displayName,
                span: place.span,
                categoryID: "location"
            ))
        }
        for segment in travel {
            append(RecordGraphNode(
                id: "automatic.travel.\(segment.id.uuidString)",
                layer: .automatic,
                title: MovementPresentation.title(for: segment.mode),
                span: segment.span,
                categoryID: "movement"
            ))
        }
        for actual in actuals where isAutomaticActual(actual) {
            append(RecordGraphNode(
                id: "automatic.actual.\(actual.id.uuidString)",
                layer: .automatic,
                title: actual.categoryID == "movement"
                    ? MovementPresentation.title(for: actual)
                    : actual.title,
                span: actual.span(),
                categoryID: actual.categoryID
            ))
        }

        // Repeat-rule segments are projections of a routine, not separate
        // relationship nodes. Keeping them here made one routine appear as
        // several duplicate cards and caused evidence to link to a phantom
        // action. The root routine owns the rule; concrete actions remain
        // separate nodes.
        for plan in plans where isRoutine(plan) {
            append(RecordGraphNode(
                id: "routine.\(plan.id.uuidString)",
                layer: .routine,
                title: GoalRecordPolicy.displayTitle(plan.title),
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }
        for plan in plans where isAction(plan) {
            append(RecordGraphNode(
                id: "action.\(plan.id.uuidString)",
                layer: .action,
                title: plan.title,
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }

        let routines = allNodes.filter { $0.layer == .routine }
        let actions = allNodes.filter { $0.layer == .action }
        for action in actions {
            guard let actionID = UUID(
                uuidString: action.id.replacingOccurrences(of: "action.", with: "")
            ), let routineID = rootRoutineID(
                for: actionID,
                plansByID: plansByID
            ) else {
                continue
            }
            let routineNodeID = "routine.\(routineID.uuidString)"
            guard routines.contains(where: { $0.id == routineNodeID }) else {
                continue
            }
            appendEdge(from: routineNodeID, to: action.id)
        }

        for actual in actuals {
            let actualNodeID = "automatic.actual.\(actual.id.uuidString)"
            guard nodeIDs.contains(actualNodeID) else { continue }
            if let routineID = routineID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "routine.\(routineID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
            if let planID = actionID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "action.\(planID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
        }

        for link in recordLinks {
            let from = canonicalNodeID(link.fromNodeID, plansByID: plansByID)
            let to = canonicalNodeID(link.toNodeID, plansByID: plansByID)
            guard from != to,
                  nodeIDs.contains(from),
                  nodeIDs.contains(to) else { continue }
            appendEdge(from: from, to: to)
        }

        let visibleIDs: Set<String>
        if let focusNodeID {
            let canonicalFocus = canonicalNodeID(focusNodeID, plansByID: plansByID)
            var connected = Set([canonicalFocus])
            var changed = true
            while changed {
                changed = false
                for edge in edges where connected.contains(edge.from) || connected.contains(edge.to) {
                    if connected.insert(edge.from).inserted { changed = true }
                    if connected.insert(edge.to).inserted { changed = true }
                }
            }
            visibleIDs = connected
        } else {
            visibleIDs = Set(
                allNodes
                    .filter { $0.span.intersection(with: span) != nil }
                    .map(\.id)
            )
        }
        let nodes = allNodes.filter { visibleIDs.contains($0.id) }
        let visibleEdges = edges.filter {
            visibleIDs.contains($0.from) && visibleIDs.contains($0.to)
        }
        return RecordRelationshipGraph(
            nodes: nodes.sorted { lhs, rhs in
                let leftLayer = RecordLayer.allCases.firstIndex(of: lhs.layer) ?? 0
                let rightLayer = RecordLayer.allCases.firstIndex(of: rhs.layer) ?? 0
                return leftLayer == rightLayer
                    ? lhs.span.start < rhs.span.start
                    : leftLayer < rightLayer
            },
            edges: visibleEdges
        )
    }

    private static func isAutomaticActual(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "sleep"
            || actual.categoryID == "activity"
            || actual.source == .healthKit
            || actual.source == .appleWatch
            || actual.source == .motion
            || actual.source == .location
            || actual.source == .media
            || actual.source == .call
    }

    private static func isRoutine(_ plan: PlanRecord) -> Bool {
        GoalRecordPolicy.isGoal(plan)
    }

    private static func isAction(_ plan: PlanRecord) -> Bool {
        !GoalRecordPolicy.isGoal(plan)
            && plan.origin != .repeatRule
            && plan.origin != .calendar
    }

    private static func rootRoutineID(
        for planID: UUID,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = plansByID[id] {
            if GoalRecordPolicy.isGoal(plan) {
                return plan.id
            }
            currentID = plan.parentID
        }
        return nil
    }

    private static func routineID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        if let routineID = actual.routineID,
           let rootID = rootRoutineID(for: routineID, plansByID: plansByID) {
            return rootID
        }
        guard let planID = actual.planID else { return nil }
        return rootRoutineID(for: planID, plansByID: plansByID)
    }

    private static func actionID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual),
              let planID = actual.planID,
              let plan = plansByID[planID],
              isAction(plan) else {
            return nil
        }
        return plan.id
    }

    private static func canonicalNodeID(
        _ nodeID: String,
        plansByID: [UUID: PlanRecord]
    ) -> String {
        let prefixes = ["routine.", "action."]
        guard let prefix = prefixes.first(where: { nodeID.hasPrefix($0) }),
              let id = UUID(uuidString: String(nodeID.dropFirst(prefix.count))) else {
            return nodeID
        }
        guard let plan = plansByID[id] else { return nodeID }
        if let rootID = rootRoutineID(for: plan.id, plansByID: plansByID) {
            if prefix == "routine." || plan.origin == .repeatRule {
                return "routine.\(rootID.uuidString)"
            }
        }
        return nodeID
    }

}

/// 지난 날의 날씨를 그 시각의 GPS 위치 기준으로 고정한다(WTH1020C01). 미래는 현재 위치 예보, 과거는 GPS 위치의 실제 날씨.
/// 하루를 시(hour)로 나눠 각 시의 위치(가운데 시각에 가장 가까운 GPS, 없으면 집)를 정하고, 가까운 연속한 시를 한 묶음으로
/// 묶어(날씨 호출 수를 줄인다) 묶음마다 시간별 날씨를 받아 해당 시의 기존 날씨를 교체한다.
enum WeatherDayFixEngine {
    struct HourLocation: Equatable {
        var hourStart: Date
        var hourEnd: Date
        var point: GeoPoint
    }

    struct Group: Equatable {
        var point: GeoPoint
        var start: Date
        var end: Date
        var hours: [HourLocation]
    }

    /// 같은 묶음으로 보는 최대 거리(첫 시의 위치 기준).
    static let groupRadiusMeters = 1_000.0
    /// 이보다 부정확한 위치 점은 날씨 위치로 쓰지 않는다.
    static let maximumAccuracyMeters = 1_000.0

    static func hourLocations(
        dayStart: Date,
        dayEnd: Date,
        readings: [SensorReading],
        home: GeoPoint?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HourLocation] {
        let located = readings
            .filter {
                guard let point = $0.point else { return false }
                return point.horizontalAccuracy >= 0
                    && point.horizontalAccuracy <= maximumAccuracyMeters
                    && $0.timestamp >= dayStart && $0.timestamp < dayEnd
            }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [HourLocation] = []
        var cursor = dayStart
        var index = 0
        while cursor < dayEnd,
              let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next > cursor {
            let middle = cursor.addingTimeInterval(next.timeIntervalSince(cursor) / 2)
            while index + 1 < located.count,
                  abs(located[index + 1].timestamp.timeIntervalSince(middle))
                    <= abs(located[index].timestamp.timeIntervalSince(middle)) {
                index += 1
            }
            if let reading = located.isEmpty ? nil : located[index], let point = reading.point {
                result.append(HourLocation(hourStart: cursor, hourEnd: next, point: point))
            } else if let home {
                result.append(HourLocation(hourStart: cursor, hourEnd: next, point: home))
            }
            cursor = next
        }
        return result
    }

    static func groups(_ hours: [HourLocation]) -> [Group] {
        var result: [Group] = []
        for hour in hours {
            if var last = result.last,
               last.hours.last?.hourEnd == hour.hourStart,
               distanceMeters(last.point, hour.point) <= groupRadiusMeters {
                last.end = hour.hourEnd
                last.hours.append(hour)
                result[result.count - 1] = last
            } else {
                result.append(Group(point: hour.point, start: hour.hourStart, end: hour.hourEnd, hours: [hour]))
            }
        }
        return result
    }

    /// 고정한 시의 기존 날씨(예보·관측 모두)를 빼고 고정 값을 넣는다. 받지 못한 시의 기존 값은 그대로 둔다.
    static func replacing(
        _ existing: [WeatherContext],
        withFixed fixed: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [WeatherContext] {
        let fixedBuckets = Set(fixed.map { WeatherTimelineEngine.hourBucket(for: $0.observedAt, calendar: calendar) })
        let kept = existing.filter {
            !fixedBuckets.contains(WeatherTimelineEngine.hourBucket(for: $0.observedAt, calendar: calendar))
        }
        return (kept + fixed).sorted { $0.observedAt < $1.observedAt }
    }
}

enum WeatherTimelineEngine {
    static let defaultDuration: TimeInterval = 15 * 60

    private struct Signature: Equatable {
        let condition: String
        let symbolName: String
        let temperature: Int
        let airGrade: AirQualityGrade?
        let location: LocationSignature
    }

    private struct LocationSignature: Equatable {
        let placeID: UUID?
        let latitude: Int?
        let longitude: Int?

        init(_ context: WeatherContext) {
            placeID = context.placeID
            guard context.placeID == nil, let point = context.point else {
                latitude = nil
                longitude = nil
                return
            }
            latitude = Int((point.latitude * 1_000).rounded())
            longitude = Int((point.longitude * 1_000).rounded())
        }
    }

    /// Returns the local-clock hour used as the stable replacement key for a
    /// weather observation and its forecast.
    static func hourBucket(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    /// Replaces only the same location/time projection. Raw weather samples
    /// remain append-only in the device archive; this value is the persisted
    /// display projection.
    static func replacing(
        _ existing: [WeatherContext],
        current: WeatherContext? = nil,
        forecast: [WeatherContext] = [],
        forecastRange: TimeSpan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [WeatherContext] {
        let currentBucket = current.map {
            hourBucket(for: $0.observedAt, calendar: calendar)
        }
        var incomingForecast = deduplicated(
            forecast,
            calendar: calendar
        )
        if let current, let currentBucket {
            incomingForecast.removeAll {
                matches($0, current)
                    && hourBucket(for: $0.observedAt, calendar: calendar)
                        == currentBucket
            }
        }

        let kept = existing.filter { value in
            if let current, let currentBucket,
               matches(value, current),
               hourBucket(for: value.observedAt, calendar: calendar)
                    == currentBucket {
                return false
            }
            if let forecastRange, !incomingForecast.isEmpty,
               value.isForecast == true, value.placeID == nil,
               !(value.observedAt >= forecastRange.start
                    && value.observedAt < forecastRange.end) {
                return false
            }
            guard let forecastRange, !incomingForecast.isEmpty,
                  value.observedAt >= forecastRange.start,
                  value.observedAt < forecastRange.end else {
                return true
            }
            return !incomingForecast.contains {
                matches(value, $0)
                    && hourBucket(for: value.observedAt, calendar: calendar)
                        == hourBucket(
                            for: $0.observedAt,
                            calendar: calendar
                        )
            }
        }

        var result = kept
        if let current {
            result.append(current)
        }
        result.append(contentsOf: incomingForecast)
        return coalesced(result)
    }

    static func span(
        for context: WeatherContext,
        defaultDuration: TimeInterval = 15 * 60
    ) -> TimeSpan {
        let fallbackEnd = context.observedAt.addingTimeInterval(defaultDuration)
        return TimeSpan(
            start: context.observedAt,
            end: max(
                context.observedAt.addingTimeInterval(1),
                context.validUntil ?? fallbackEnd
            )
        )
    }

    static func coalesced(
        _ contexts: [WeatherContext],
        defaultDuration: TimeInterval = 15 * 60
    ) -> [WeatherContext] {
        var seen = Set<UUID>()
        // Open-Meteo's free tier forbids commercial use, so its rows are
        // retired on load and raw replay. The raw envelopes stay untouched.
        let ordered = contexts
            .filter { !$0.isFromRetiredProvider && seen.insert($0.id).inserted }
            .sorted { $0.observedAt < $1.observedAt }
        var result: [WeatherContext] = []
        result.reserveCapacity(ordered.count)

        for original in ordered {
            var current = original
            if current.airQuality?.isFromRetiredProvider == true { current.airQuality = nil }
            current.validUntil = span(
                for: current,
                defaultDuration: defaultDuration
            ).end
            if current.isForecast == true, current.placeID == nil,
               let index = result.lastIndex(where: {
                   $0.isForecast == true && $0.placeID == nil
                       && hourBucket(for: $0.observedAt)
                           == hourBucket(for: current.observedAt)
               }) {
                if (current.fetchedAt ?? .distantPast)
                    >= (result[index].fetchedAt ?? .distantPast) {
                    result[index] = current
                }
                continue
            }
            guard let lastIndex = result.indices.last else {
                result.append(current)
                continue
            }

            let last = result[lastIndex]
            let lastSpan = span(for: last, defaultDuration: defaultDuration)
            if signature(last) == signature(current) {
                result[lastIndex].validUntil = max(
                    lastSpan.end,
                    span(for: current, defaultDuration: defaultDuration).end
                )
                // Keep the most recent detail values while preserving one
                // continuous block for the same displayed weather.
                result[lastIndex].airQuality = current.airQuality
                result[lastIndex].point = current.point ?? result[lastIndex].point
                result[lastIndex].placeID = current.placeID ?? result[lastIndex].placeID
                result[lastIndex].placeName = current.placeName ?? result[lastIndex].placeName
                if let fetchedAt = current.fetchedAt,
                   fetchedAt > (result[lastIndex].fetchedAt ?? .distantPast) {
                    result[lastIndex].fetchedAt = fetchedAt
                    result[lastIndex].isStale = current.isStale
                }
            } else {
                result[lastIndex].validUntil = current.observedAt
                result.append(current)
            }
        }
        return result
    }

    /// Returns only the points where the displayed weather changes. The raw
    /// archive keeps those transition points; the full timeline is rebuilt by
    /// carrying each value forward until the next point.
    static func changedRawContexts(
        _ incoming: [WeatherContext],
        relativeTo existing: [WeatherContext]
    ) -> [WeatherContext] {
        var timeline = existing
        var changes: [WeatherContext] = []
        for context in incoming.sorted(by: {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let previous = timeline
                .filter {
                    sameRawStream($0, context)
                        && $0.observedAt <= context.observedAt
                }
                .max {
                    if $0.observedAt != $1.observedAt {
                        return $0.observedAt < $1.observedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
            guard let previous else {
                changes.append(context)
                timeline.append(context)
                continue
            }
            if rawDisplaySignature(previous) != rawDisplaySignature(context) {
                changes.append(context)
            }
            timeline.append(context)
        }
        return changes
    }

    private static func signature(_ context: WeatherContext) -> Signature {
        Signature(
            condition: context.condition,
            symbolName: context.symbolName,
            temperature: AppRegion.current.temperature(celsius: context.temperatureCelsius),
            // Merge by what the timeline shows.  Raw PM values, provider and
            // fallback state belong to the detail view and must not split a
            // visually identical weather run.
            airGrade: context.airQuality?.overallGrade,
            location: LocationSignature(context)
        )
    }

    private struct RawDisplaySignature: Equatable {
        let symbolName: String
        let temperature: Int
        let airGrade: AirQualityGrade?
        let location: LocationSignature?
    }

    private static func sameRawStream(
        _ lhs: WeatherContext,
        _ rhs: WeatherContext
    ) -> Bool {
        guard (lhs.isForecast == true) == (rhs.isForecast == true) else {
            return false
        }
        guard lhs.placeID == rhs.placeID else { return false }
        if lhs.isForecast == true, lhs.placeID == nil { return true }
        guard lhs.placeID == nil else { return true }
        return LocationSignature(lhs) == LocationSignature(rhs)
    }

    private static func rawDisplaySignature(
        _ context: WeatherContext
    ) -> RawDisplaySignature {
        RawDisplaySignature(
            symbolName: context.symbolName,
            temperature: AppRegion.current.temperature(celsius: context.temperatureCelsius),
            airGrade: context.airQuality?.overallGrade,
            location: context.isForecast == true && context.placeID == nil
                ? nil
                : LocationSignature(context)
        )
    }

    private static func deduplicated(
        _ contexts: [WeatherContext],
        calendar: Calendar
    ) -> [WeatherContext] {
        var result: [WeatherContext] = []
        for context in contexts.sorted(by: { $0.observedAt < $1.observedAt }) {
            let bucket = hourBucket(for: context.observedAt, calendar: calendar)
            if let index = result.lastIndex(where: {
                matches($0, context)
                    && hourBucket(for: $0.observedAt, calendar: calendar)
                        == bucket
            }) {
                let previous = result[index]
                let previousFetchedAt = previous.fetchedAt ?? .distantPast
                let fetchedAt = context.fetchedAt ?? .distantPast
                if fetchedAt >= previousFetchedAt {
                    result[index] = context
                }
            } else {
                result.append(context)
            }
        }
        return result
    }

    private static func matches(
        _ lhs: WeatherContext,
        _ rhs: WeatherContext
    ) -> Bool {
        if lhs.isForecast == true, rhs.isForecast == true,
           lhs.placeID == nil, rhs.placeID == nil {
            return true
        }
        guard lhs.placeID == rhs.placeID else { return false }
        switch (lhs.point, rhs.point) {
        case let (lhsPoint?, rhsPoint?):
            return distanceMeters(lhsPoint, rhsPoint) <= 100
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}
