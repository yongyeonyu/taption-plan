import Foundation

enum PlanningError: Error, Equatable {
    case missingPlan(UUID)
    case parentCycle
    case childOutsideParent
    case invalidDuration
    case fixedPlan
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

/// Combines overlapping measured intervals without changing the source records.
/// Automatic sensors can emit the same activity from more than one device.
enum ActualIntervalMergeEngine {
    static func union(
        _ spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }

        var merged: [TimeSpan] = []
        for span in ordered.dropFirst() {
            if span.start <= current.end.addingTimeInterval(max(0, mergeGap)) {
                current.end = max(current.end, span.end)
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }

    static func duration(
        of spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> TimeInterval {
        union(spans, mergeGap: mergeGap).reduce(0) {
            $0 + $1.duration
        }
    }

    /// `span` 에서 `covered` 가 덮은 시간을 뺀 나머지 조각. 조각은 시작 시각
    /// 순이고 서로 겹치지 않는다. `covered` 는 정렬돼 있지 않아도 된다.
    static func subtracting(
        _ covered: [TimeSpan],
        from span: TimeSpan
    ) -> [TimeSpan] {
        guard span.duration > 0 else { return [] }
        var remaining: [TimeSpan] = []
        var cursor = span.start
        for block in union(covered, mergeGap: 0)
        where block.end > span.start && block.start < span.end {
            if block.start > cursor {
                remaining.append(
                    TimeSpan(start: cursor, end: min(block.start, span.end))
                )
            }
            cursor = max(cursor, block.end)
            if cursor >= span.end { break }
        }
        if cursor < span.end {
            remaining.append(TimeSpan(start: cursor, end: span.end))
        }
        return remaining.filter { $0.duration > 0 }
    }
}

/// Keeps measured movement records as raw evidence while showing one
/// canonical travel segment when the route inference covers that interval.
enum MovementDisplayEngine {
    static func reviewActuals(
        _ actuals: [ActualRecord],
        travel: [TravelSegment],
        calendarEvents: [CalendarRecord] = [],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let canonical = travel.compactMap { segment -> ActualRecord? in
            let end = min(segment.span.end, date)
            guard end > segment.span.start else { return nil }
            let isConfirmedBySchedule = hasScheduledEvent(
                segment.span,
                in: calendarEvents
            )
            let isConfirmed = segment.isConfirmed
                || segment.confidence == .high
                || isConfirmedBySchedule
            let title = MovementPresentation.title(for: segment.mode)
            return ActualRecord(
                id: segment.id,
                planID: nil,
                title: isConfirmed ? title : "\(title) (미확인)",
                categoryID: isConfirmed ? "movement" : "unconfirmed",
                startedAt: segment.span.start,
                endedAt: end,
                source: .location,
                confidence: segment.confidence,
                createdAt: segment.span.start,
                behavior: segment.mode.rawValue,
                evidence: segment.evidence,
                manuallyCorrected: isConfirmed
            )
        }
        return visibleActuals(actuals, travel: travel, asOf: date) + canonical
    }

    private static func hasScheduledEvent(
        _ span: TimeSpan,
        in events: [CalendarRecord]
    ) -> Bool {
        guard span.duration > 0 else { return false }
        return events.contains { event in
            !event.isAllDay
                && event.isCancelled != true
                && (event.span.intersection(with: span)?.duration ?? 0) > 0
        }
    }

    static func visibleActuals(
        _ actuals: [ActualRecord],
        travel: [TravelSegment],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        let travelSpans = travel.map(\.span)
        return actuals.flatMap { actual -> [ActualRecord] in
            guard isMovementRecord(actual) else {
                return [actual]
            }
            guard isReliable(actual) else { return [] }
            let span = actual.span(asOf: date)
            guard span.duration > 0 else { return [] }
            let remainders = ActualIntervalMergeEngine.subtracting(
                travelSpans,
                from: span
            )
            return remainders.enumerated().map { offset, remainder in
                var value = actual
                value.id = offset == 0
                    ? actual.id
                    : remainderID(actual.id, offset: offset)
                value.startedAt = remainder.start
                value.endedAt = remainder.end
                return value
            }
        }
    }

    /// 위치 체류에서 오래 이어진 보행 후보와 저신뢰 기본 후보는 이동 결과로
    /// 쓰지 않는다. 걷기·달리기·자전거는 사용자 교정, 운동 기록 또는 높은
    /// 신뢰도의 모션 판정이 있을 때만 남긴다.
    private static func isReliable(_ actual: ActualRecord) -> Bool {
        guard let mode = MovementPresentation.mode(for: actual) else {
            return actual.confidence != .low
        }
        guard [.walking, .running, .cycling].contains(mode) else { return true }
        if actual.manuallyCorrected || actual.source == .manual
            || actual.source == .timer {
            return true
        }
        guard actual.source != .location, actual.confidence == .high else {
            return false
        }
        if actual.source == .healthKit || actual.source == .appleWatch {
            return true
        }
        let evidence = actual.evidence.joined(separator: " ").lowercased()
        return actual.source == .motion
            || ["걸음", "cadence", "보폭", "pedometer", "gps", "core motion"]
                .contains { evidence.contains($0) }
    }

    private static func isMovementRecord(_ actual: ActualRecord) -> Bool {
        guard actual.categoryID != "appUsage" else { return false }
        return actual.categoryID == "movement"
            || MovementPresentation.mode(for: actual) != nil
    }

    private static func remainderID(_ id: UUID, offset: Int) -> UUID {
        var bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var hash = UInt64(14_695_981_039_346_656_037) &+ UInt64(offset)
        for index in bytes.indices {
            hash ^= UInt64(bytes[index])
            hash = hash &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 잠든 시간은 정지 문맥에서도 "집에서 휴식"이나 "생활"로 잡힌다. 두 기록을
/// 그대로 두면 같은 시각을 정지 문맥과 수면이 각각 세어 하루 합계가 흐른
/// 시간을 넘는다.
/// 측정된 원본은 그대로 두고, 화면과 합계가 함께 읽는 값에서만 수면이 덮은
/// 만큼을 덜어 낸다. 수면이 통째로 덮은 기록만 사라지고 나머지는 남는다.
enum RestSleepDisplayEngine {
    static func isRest(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "rest"
            || actual.behavior == "cafe"
            || actual.behavior == "homeRest"
    }

    static func yieldsToSleep(_ actual: ActualRecord) -> Bool {
        isRest(actual)
            || actual.categoryID == "routine"
            || actual.behavior == "housework"
    }

    static func visibleActuals(
        _ actuals: [ActualRecord],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        guard actuals.contains(where: yieldsToSleep) else { return actuals }
        let sleepSpans = ActualIntervalMergeEngine.union(
            actuals
                .filter(AutomaticRecordTimelineEngine.isSleep)
                .map { $0.span(asOf: date) },
            mergeGap: 0
        )
        guard !sleepSpans.isEmpty else { return actuals }

        return actuals.flatMap { actual -> [ActualRecord] in
            guard yieldsToSleep(actual) else { return [actual] }
            let span = actual.span(asOf: date)
            guard span.duration > 0 else { return [actual] }
            let remainders = ActualIntervalMergeEngine.subtracting(
                sleepSpans,
                from: span
            )
            guard remainders != [span] else { return [actual] }
            return remainders.enumerated().map { offset, remainder in
                var trimmed = actual
                // 첫 조각이 원본 식별자를 지켜야 기록 상세로 넘어갈 수 있고,
                // 나머지 조각도 서로 다른 식별자라야 목록에서 지워지지 않는다.
                trimmed.id = offset == 0
                    ? actual.id
                    : remainderID(of: actual.id, offset: offset)
                trimmed.startedAt = remainder.start
                trimmed.endedAt = actual.endedAt == nil && remainder.end >= date
                    ? nil
                    : remainder.end
                return trimmed
            }
        }
    }

    /// 같은 기록을 다시 잘라도 같은 값이 나와야 화면 갱신마다 선택이 풀리지
    /// 않는다. 자동 기록의 안정된 식별자와 같은 방식으로 만든다.
    private static func remainderID(of id: UUID, offset: Int) -> UUID {
        var bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var hash = UInt64(14_695_981_039_346_656_037) &+ UInt64(offset)
        for index in bytes.indices {
            hash ^= UInt64(bytes[index])
            hash = hash &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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

enum AutomaticRecordTimelineEngine {
    /// Device/HealthKit records are ground truth. Their timestamps and
    /// measured duration must never be changed by the plan editor or the
    /// routine progress slider.
    static func isImmutable(_ actual: ActualRecord) -> Bool {
        switch actual.source {
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        case .manual, .timer, .calendar, .photo:
            false
        }
    }

    static func isSleep(_ actual: ActualRecord) -> Bool {
        // 앱 이름은 임의의 낱말이라 제목만 보고 수면으로 오인하면 안 된다.
        if actual.categoryID == "appUsage" { return false }
        return actual.categoryID == "sleep"
            || actual.title.localizedCaseInsensitiveContains("수면")
            || actual.title.localizedCaseInsensitiveContains("취침")
            || actual.title.localizedCaseInsensitiveContains("sleep")
    }

    static func isRoutineOnlyCategory(_ categoryID: String) -> Bool {
        categoryID == "sleep" || categoryID == "activity"
    }

    static func linksOnlyToRoutine(_ actual: ActualRecord) -> Bool {
        isRoutineOnlyCategory(actual.categoryID)
    }

    static func activities(
        from actuals: [ActualRecord],
        inside span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        visibleThroughNow(actuals, asOf: asOf)
            .filter {
                ($0.source == .healthKit
                    || $0.source == .appleWatch
                    || $0.source == .motion
                    || $0.source == .location
                    || $0.source == .media
                    || $0.source == .call
                    || $0.source == .appUsage)
                    && $0.span(asOf: asOf).intersection(with: span) != nil
            }
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.span(asOf: asOf).end
                        < $1.span(asOf: asOf).end
                }
                return $0.startedAt < $1.startedAt
            }
    }

    /// 화면에 걸치는 기록만 잘라 낸다.  전체 기록을 먼저 복사한 뒤 걸러 내면
    /// 배율을 바꿀 때마다 보이지도 않는 기록까지 구조체를 새로 만든다.
    static func visibleThroughNow(
        _ actuals: [ActualRecord],
        intersecting span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        actuals.compactMap { actual in
            guard actual.startedAt < asOf,
                  actual.startedAt < span.end else { return nil }
            let observedEnd = min(actual.endedAt ?? asOf, asOf)
            guard max(actual.startedAt, observedEnd) > span.start else {
                return nil
            }
            var visible = actual
            if visible.endedAt == nil || visible.endedAt! > asOf {
                visible.endedAt = asOf
            }
            return visible
        }
    }

    /// Automatic records are observations, not forecasts.  Keep the source
    /// record immutable while clipping the copy used by timelines/widgets to
    /// the current instant.
    static func visibleThroughNow(
        _ actuals: [ActualRecord],
        asOf: Date = .now
    ) -> [ActualRecord] {
        actuals.compactMap { actual in
            guard actual.startedAt <= asOf else { return nil }
            var visible = actual
            if visible.endedAt == nil || visible.endedAt! > asOf {
                visible.endedAt = asOf
            }
            return visible
        }
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

    func hierarchySummaries(
        for level: TimelineLevel,
        containing date: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> [TimelineLevel: [SummaryBucket]] {
        let childLevels: [TimelineLevel] = switch level {
        case .day: []
        case .week: [.day]
        case .month: [.week, .day]
        case .year: [.month, .week, .day]
        }
        let outer = interval(for: level, containing: date)
        return Dictionary(
            uniqueKeysWithValues: childLevels.map { childLevel in
                (
                    childLevel,
                    buckets(
                        of: childLevel,
                        inside: outer,
                        plans: plans,
                        actuals: actuals,
                        photos: photos,
                        asOf: asOf
                    )
                )
            }
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

enum ScheduleEditEngine {
    static let dragSnap: TimeInterval = 15 * 60

    static func move(
        _ plan: PlanRecord,
        by delta: TimeInterval
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let snapped = (delta / dragSnap).rounded() * dragSnap
        var value = plan
        value.span = TimeSpan(
            start: plan.span.start.addingTimeInterval(snapped),
            end: plan.span.end.addingTimeInterval(snapped)
        )
        value.updatedAt = .now
        return value
    }

    static func resize(
        _ plan: PlanRecord,
        newStart: Date? = nil,
        newEnd: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let start = snap(newStart ?? plan.span.start)
        let end = snap(newEnd ?? plan.span.end)
        guard start < end else { throw PlanningError.invalidDuration }
        var value = plan
        value.span = TimeSpan(start: start, end: end)
        value.updatedAt = .now
        return value
    }

    private static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(
            timeIntervalSinceReferenceDate: (seconds / dragSnap).rounded() * dragSnap
        )
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
        guard !actuals.contains(where: {
            $0.planID == plan.id || $0.routineID == plan.id
        }) else {
            return false
        }
        let nodeIDs: Set<String> = [
            "action.\(plan.id.uuidString)",
            "routine.\(plan.id.uuidString)",
        ]
        return !recordLinks.contains {
            nodeIDs.contains($0.fromNodeID) || nodeIDs.contains($0.toNodeID)
        }
    }

    /// Idempotent: once the placeholders are gone a second run finds nothing.
    static func apply(to snapshot: inout TaptionDataSnapshot) {
        let shells = snapshot.plans.filter {
            isShell(
                $0,
                actuals: snapshot.actuals,
                recordLinks: snapshot.recordLinks
            )
        }
        guard !shells.isEmpty else { return }
        let shellsByID = Dictionary(
            shells.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        snapshot.memos = snapshot.memos.map { memo in
            guard let planID = memo.planID,
                  let shell = shellsByID[planID] else {
                return memo
            }
            var lifted = memo
            lifted.planID = nil
            if lifted.targetID == "plan.\(planID.uuidString)" {
                lifted.targetID = nil
            }
            lifted.categoryID = memo.categoryID ?? shell.categoryID
            lifted.occurredAt = shell.span.start
            return lifted
        }
        snapshot.plans.removeAll { shellsByID[$0.id] != nil }
    }
}

enum ActualRecordSuppressionEngine {
    static func visibleRecords(
        from records: [ActualRecord],
        suppressedIDs: Set<UUID>
    ) -> [ActualRecord] {
        records.filter { !suppressedIDs.contains($0.id) }
    }
}

struct QuickActionResult: Sendable {
    var plan: PlanRecord
    var actuals: [ActualRecord]
}

enum QuickActionEngine {
    static func start(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .running
        updated.updatedAt = date

        guard !actuals.contains(where: { $0.planID == plan.id && $0.endedAt == nil }) else {
            return QuickActionResult(plan: updated, actuals: actuals)
        }
        var values = actuals
        values.append(
            ActualRecord(
                planID: plan.id,
                title: plan.title,
                categoryID: plan.categoryID,
                startedAt: date,
                source: .timer
            )
        )
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func complete(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now,
        copyPlannedDurationWhenMissing: Bool = false
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .completed
        updated.updatedAt = date
        var values = actuals

        if let runningIndex = values.lastIndex(where: {
            $0.planID == plan.id && $0.endedAt == nil
        }) {
            values[runningIndex].endedAt = max(
                values[runningIndex].startedAt,
                date
            )
        } else if copyPlannedDurationWhenMissing {
            values.append(
                ActualRecord(
                    planID: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startedAt: plan.span.start,
                    endedAt: plan.span.end,
                    source: .manual
                )
            )
        }
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func postpone(
        plan: PlanRecord,
        by interval: TimeInterval = 30 * 60
    ) throws -> PlanRecord {
        try ScheduleEditEngine.move(plan, by: interval)
    }

    static func skip(
        plan: PlanRecord,
        at date: Date = .now
    ) -> PlanRecord {
        var value = plan
        value.status = .skipped
        value.updatedAt = date
        return value
    }

    static func moveToNextFreeTime(
        plan: PlanRecord,
        occupied: [TimeSpan],
        after date: Date = .now,
        searchLimit: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let duration = plan.span.duration
        guard duration > 0 else { throw PlanningError.invalidDuration }
        let limit = searchLimit ?? date.addingTimeInterval(14 * 86_400)
        let sorted = occupied
            .filter { $0.end > date }
            .sorted { $0.start < $1.start }
        var candidate = date

        for block in sorted {
            if candidate.addingTimeInterval(duration) <= block.start {
                break
            }
            if candidate < block.end {
                candidate = block.end
            }
            guard candidate.addingTimeInterval(duration) <= limit else {
                throw PlanningError.invalidDuration
            }
        }

        var value = plan
        value.span = TimeSpan(
            start: candidate,
            end: candidate.addingTimeInterval(duration)
        )
        value.updatedAt = .now
        return value
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
        asOf: Date = .now
    ) -> ReviewReport {
        report(
            over: [aggregation.interval(for: level, containing: date)],
            plans: plans,
            actuals: actuals,
            weather: weather,
            photos: photos,
            memos: memos,
            asOf: asOf
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
        asOf: Date = .now
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

        var planned: [String: TimeInterval] = [:]
        var actual: [String: TimeInterval] = [:]
        for span in ordered {
            let bucket = aggregation.summary(
                of: span,
                plans: plans,
                actuals: actuals,
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

        let knownPlanIDs = Set(plans.map(\.id))
        let unplanned = actuals.reduce(0) { partial, actual in
            guard actual.planID == nil || !knownPlanIDs.contains(actual.planID!) else {
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
                    text: "\($0.condition) · \(Int($0.temperatureCelsius.rounded()))°\(airQualityText)",
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

enum GoalRecordPolicy {
    static let currentPrefix = "루틴:"
    static let legacyPrefix = "목표:"

    static func isGoal(_ plan: PlanRecord) -> Bool {
        guard plan.parentID == nil else { return false }
        let title = plan.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.hasPrefix(currentPrefix)
            || title.hasPrefix(legacyPrefix)
    }

    static func displayTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix(currentPrefix) {
            return title
        }
        if title.hasPrefix(legacyPrefix) {
            return currentPrefix + title.dropFirst(legacyPrefix.count)
        }
        return currentPrefix + title
    }

    static func visibleGoals(in plans: [PlanRecord]) -> [PlanRecord] {
        plans
            .filter { isGoal($0) && $0.status != .skipped }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
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
        let covered = unionDuration(spans)
        return min(1, max(0, covered / plan.span.duration))
    }

    static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
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
    var hasConnections: Bool { !edges.isEmpty }
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
                title: travelTitle(segment.mode),
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

    private static func travelTitle(_ mode: TravelMode) -> String {
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
}

enum WeatherTimelineEngine {
    static let defaultDuration: TimeInterval = 15 * 60

    private struct Signature: Equatable {
        let condition: String
        let temperature: Int
        let airGrade: AirQualityGrade?
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
        let ordered = contexts
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.observedAt < $1.observedAt }
        var result: [WeatherContext] = []
        result.reserveCapacity(ordered.count)

        for original in ordered {
            var current = original
            current.validUntil = span(
                for: current,
                defaultDuration: defaultDuration
            ).end
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

    private static func signature(_ context: WeatherContext) -> Signature {
        Signature(
            condition: context.condition,
            temperature: Int(context.temperatureCelsius.rounded()),
            // Merge by what the timeline shows.  Raw PM values, provider and
            // fallback state belong to the detail view and must not split a
            // visually identical weather run.
            airGrade: context.airQuality?.overallGrade
        )
    }
}

enum TimelineCoordinateMapper {
    static func fraction(
        for date: Date,
        in viewport: TimelineViewport
    ) -> Double {
        let visibleStart = viewport.dayStart.addingTimeInterval(
            viewport.horizontalOffset
        )
        return date.timeIntervalSince(visibleStart) / viewport.visibleSpan
    }

    static func date(
        at fraction: Double,
        in viewport: TimelineViewport
    ) -> Date {
        viewport.dayStart.addingTimeInterval(
            viewport.horizontalOffset + fraction * viewport.visibleSpan
        )
    }

    static func pan(
        _ viewport: TimelineViewport,
        by interval: TimeInterval
    ) -> TimelineViewport {
        var value = viewport
        value.horizontalOffset = max(0, value.horizontalOffset + interval)
        value.followsCurrentTime = false
        return value
    }

    static func zoom(
        _ viewport: TimelineViewport,
        factor: Double,
        anchor: Double = 0.5
    ) -> TimelineViewport {
        var value = viewport
        let oldSpan = viewport.visibleSpan
        let newSpan = min(86_400, max(15 * 60, oldSpan / max(0.1, factor)))
        let anchorOffset = viewport.horizontalOffset + oldSpan * anchor
        value.visibleSpan = newSpan
        value.horizontalOffset = max(0, anchorOffset - newSpan * anchor)
        value.followsCurrentTime = false
        return value
    }

    static func followNow(
        _ viewport: TimelineViewport,
        now: Date = .now,
        anchor: Double = 0.6
    ) -> TimelineViewport {
        var value = viewport
        value.currentTime = now
        value.horizontalOffset = max(
            0,
            now.timeIntervalSince(viewport.dayStart) - viewport.visibleSpan * anchor
        )
        value.followsCurrentTime = true
        return value
    }
}

enum WidgetSnapshotFactory {
    static func make(
        plans: [PlanRecord],
        now: Date,
        catStyle: CatStyle,
        hideSensitiveContent: Bool,
        horizon: TimeInterval = 4 * 3_600
    ) -> WidgetSnapshot {
        let viewport = TimeSpan(
            start: now.addingTimeInterval(-horizon / 2),
            end: now.addingTimeInterval(horizon / 2)
        )
        let visiblePlans = plans
            .filter { $0.span.intersection(with: viewport) != nil && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
        let items = visiblePlans.map { plan in
            WidgetTimelineItem(
                id: plan.id,
                title: plan.title,
                span: plan.span,
                categoryID: plan.categoryID,
                isCurrent: plan.span.contains(now) && plan.status != .completed
            )
        }
        return WidgetSnapshot(
            generatedAt: now,
            viewport: viewport,
            items: items,
            availableActions: [],
            catStyle: catStyle,
            catIsRunning: items.contains(where: \.isCurrent),
            hidesSensitiveContent: hideSensitiveContent
        )
    }
}
