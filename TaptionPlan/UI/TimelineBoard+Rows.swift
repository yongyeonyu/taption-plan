import SwiftUI
import UIKit
import MapKit

extension TimelineBoard {
    func rows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let resolved = resolvedRows(in: span, index: index)
        // Do not synthesize sample rows when the user has no records. Apart
        // from showing misleading plans, those placeholder blocks forced the
        // board to build and diff several extra rows on every viewport tick.
        return resolved
    }

    func finishRowDrop(
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

    func resolvedRows(
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

    func rows(
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
        let relevantTravel = TravelSegmentPresentationEngine.consolidated(
            model.snapshot.travel.filter {
                $0.span.intersection(with: span) != nil
            }
        )
        let visibleActuals = AutomaticRecordTimelineEngine.visibleThroughNow(
            model.snapshot.actuals,
            intersecting: span,
            asOf: now
        )
            .sorted { $0.startedAt < $1.startedAt }
        let phaseActuals = DayPhaseEvidenceEngine.records(
            from: model.snapshot.actuals,
            intersecting: span,
            asOf: now
        )
        let displayedVisibleActuals = RestSleepDisplayEngine.visibleActuals(
            MovementDisplayEngine.reviewActuals(
                visibleActuals,
                travel: relevantTravel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: now
            ),
            asOf: now
        )
        // 일·주·월이 모두 같은 줄 목록을 쓴다. 예전에는 하루만 이 경로를
        // 지나서 나머지 배율이 기록의 categoryID를 그대로 이름으로 찍었고
        // (appUsage), 줄 순서도 시간표와 어긋났다.
        let usesAutomaticDayRows = includesCalendar
        let unconfirmedActuals = model.selectedScale == .day
            ? ReviewCoverageEngine.unconfirmedRecords(
                actuals: displayedVisibleActuals,
                in: [span],
                asOf: now
            )
            : []
        var automaticActuals = AutomaticRecordTimelineEngine.activities(
            from: displayedVisibleActuals,
            inside: span
        )
        if model.selectedScale == .day {
            automaticActuals += unconfirmedActuals
        }
        let categoryVisibleActuals: [ActualRecord]
        if usesAutomaticDayRows && TaptionProductScope.automaticLoggingOnly {
            categoryVisibleActuals = []
        } else if usesAutomaticDayRows {
            categoryVisibleActuals = displayedVisibleActuals.filter {
                $0.source != .healthKit && $0.source != .appleWatch
            } + unconfirmedActuals
        } else {
            categoryVisibleActuals = displayedVisibleActuals + unconfirmedActuals
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
                contentsOf: automaticDayPhaseRows(
                    events: events,
                    actuals: phaseActuals,
                    activities: automaticActuals,
                    travel: relevantTravel,
                    visibleSpan: span,
                    index: index
                )
            )
            let appUsageActuals = displayedVisibleActuals
                .filter { $0.categoryID == TimelineRowKind.appUsage.rawValue }
            if !appUsageActuals.isEmpty {
                values.append(
                    automaticAppUsageRow(
                        actuals: appUsageActuals
                    )
                )
            }
            values.append(
                automaticLocationRow(
                    plans: grouped[
                        TimelineRowKind.location.rawValue,
                        default: []
                    ],
                    visibleSpan: span,
                    index: index
                )
            )
            values.append(automaticWeatherRow(visibleSpan: span))
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
                        systemImage: TimelineRowKind(categoryID: definition.id)?
                            .systemImage ?? definition.icon.systemImage,
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
                    // 사용자 카테고리에 없는 줄도 한글 이름으로 그린다.
                    title: TimelineRowKind.title(forCategoryID: categoryID)
                        ?? categoryID,
                    category: PlanCategory(categoryID: categoryID),
                    categoryID: categoryID,
                    systemImage: TimelineRowKind(categoryID: categoryID)?
                        .systemImage,
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

    func automaticDayPhaseRows(
        events: [CalendarRecord],
        actuals: [ActualRecord],
        activities: [ActualRecord],
        travel: [TravelSegment],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let phases = DayPhaseEngine.completePhasesAcrossDays(
            actuals: actuals,
            travel: travel,
            stays: model.snapshot.places,
            placeKinds: placeKinds,
            in: visibleSpan,
            calendar: TimelineAxisGrid.normalizedCalendar()
        )
        var values = phaseActivityValues(
            actuals: activities,
            travel: travel,
            phases: phases,
            visibleSpan: visibleSpan,
            index: index
        )
        values += events.compactMap { event in
            event.span.intersection(with: visibleSpan).map { span in
                phaseActivity(
                    seed: "calendar.\(event.id)",
                    phase: .appointment,
                    title: event.title,
                    span: span,
                    categoryID: "calendar",
                    categoryName: "일정",
                    detailText: calendarDetailText(event),
                    color: dayPhaseColor(.appointment),
                    recordNodeID: "automatic.calendar.\(event.id)"
                )
            }
        }
        values += inferredPhaseActivities(phases, coveredBy: values)

        // 왼쪽 행은 화면의 기준축이므로 기록이 없어도 같은 자리를 유지한다.
        return DayPhase.timelineRows.map { phase in
            let activities = values
                .filter { $0.phase == phase }
                .sorted { $0.span.start < $1.span.start }
            let allocation = laneAllocation(activities, span: \.span)
            return TimelineRowModel(
                title: phase.title,
                id: "dayPhase.\(phase.rawValue)",
                dotColor: dayPhaseColor(phase),
                systemImage: dayPhaseSystemImage(phase),
                fillColor: dayPhaseColor(phase).opacity(0.18),
                actualColor: dayPhaseColor(phase),
                isSystemAutomatic: true,
                height: compactAutomaticHeight(allocation.count),
                blocks: activities.map { activity in
                    timelineBlock(
                        id: activity.id,
                        title: activity.title,
                        span: activity.span,
                        top: compactAutomaticTop(
                            allocation.lanes[activity.id, default: 0]
                        ),
                        height: 14,
                        isFixed: true,
                        status: activity.isMeasured ? .completed : .planned,
                        isActual: activity.isMeasured,
                        opensLocationTimeline: activity.isRoute,
                        minimumWidth: 4,
                        detailText: activity.detailText,
                        categoryID: activity.categoryID,
                        categoryName: activity.categoryName,
                        appUsageTokenData: activity.appUsageTokenData,
                        actualID: activity.actualID,
                        travelID: activity.travelID,
                        recordNodeID: activity.recordNodeID,
                        fillColor: activity.color.opacity(0.20),
                        actualColor: activity.color,
                        styleKey: activity.styleKey,
                        minimumFraction: 0.000_001
                    )
                }
            )
        }
    }

    /// 메모 줄. 다른 줄과 달리 손으로 남긴 기록이라 자동 줄의 회색 바탕을
    /// 쓰지 않고, 줄을 누르면 하단 상세 내용만 갱신한다.
    ///
    /// 메모는 순간이라 길이가 없다. 순간마다 눈에 걸리는 최소 길이의 표식을
    /// 만들고, 배율이 넓어져 서로 구분되지 않는 표식은 `MemoTimelineEngine`
    /// 이 미리 하나로 합쳐 준다. 합쳐도 남는 자투리 너비는 막대 쪽의
    /// `minimumWidth`·`TimelineRowBarMerging` 이 다시 받아 준다.
    func memoRow(visibleSpan: TimeSpan) -> TimelineRowModel {
        let markers = MemoTimelineEngine.markers(
            from: model.timelineMemos(in: visibleSpan),
            in: visibleSpan,
            visibleDuration: visibleSpan.duration
        )
        return TimelineRowModel(
            title: TimelineRowKind.memo.title,
            id: TimelineRowKind.memo.rawValue,
            categoryID: TimelineRowKind.memo.rawValue,
            dotColor: .tpStudyDark,
            systemImage: TimelineRowKind.memo.systemImage,
            fillColor: .tpStudy,
            actualColor: .tpStudyDark,
            height: compactAutomaticHeight(1),
            blocks: markers.map { marker in
                timelineBlock(
                    id: marker.id,
                    title: marker.title,
                    span: marker.span,
                    top: compactAutomaticTop(0),
                    height: 16,
                    isFixed: true,
                    groupCount: marker.count > 1 ? marker.count : nil,
                    isActual: true,
                    minimumWidth: memoMarkerMinimumWidth,
                    detailText: marker.span.start.formatted(
                        date: .omitted,
                        time: .shortened
                    ),
                    categoryID: TimelineRowKind.memo.rawValue,
                    categoryName: TimelineRowKind.memo.title
                )
            }
        )
    }

    func automaticAppUsageRow(
        actuals: [ActualRecord]
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
                detailText: appUsageDetailText(actual),
                categoryID: "appUsage",
                categoryName: ScreenTimeUsageRecordEngine.laneTitle,
                appUsageTokenData: model.appUsageTokenIndex[actual.id]
            )
        }
        return TimelineRowModel(
            title: TimelineRowKind.appUsage.title,
            id: TimelineRowKind.appUsage.rawValue,
            dotColor: .tpProjectDark,
            systemImage: TimelineRowKind.appUsage.systemImage,
            fillColor: .tpProject,
            actualColor: .tpProjectDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    func automaticWeatherRow(
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
            title: TimelineRowKind.weather.title,
            id: TimelineRowKind.weather.rawValue,
            dotColor: .tpWeatherDark,
            systemImage: contexts.first?.symbolName
                ?? TimelineRowKind.weather.systemImage,
            fillColor: .tpWeather,
            actualColor: .tpWeatherDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    func automaticLocationRow(
        plans: [PlanRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let now = Date.now
        let visiblePlans = plans.filter { $0.span.start <= now }
        let visiblePlaces = PlaceStayPresentationEngine.consolidated(
            model.snapshot.places.compactMap { place -> PlaceStay? in
                guard place.span.start <= now,
                      place.span.start < visibleSpan.end,
                      place.span.end > visibleSpan.start,
                      let clipped = place.span.intersection(
                          with: TimeSpan(start: .distantPast, end: now)
                      ) else { return nil }
                var value = place
                value.span = clipped
                return value
            }
            .filter { $0.span.intersection(with: visibleSpan) != nil }
        )
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
            title: TimelineRowKind.location.title,
            id: TimelineRowKind.location.rawValue,
            category: .location,
            categoryID: TimelineRowKind.location.rawValue,
            systemImage: TimelineRowKind.location.systemImage,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + placeAllocation.count
            ),
            blocks: planBlocks + placeBlocks
        )
    }

    func timelineBlock(
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

    func timelineBlock(
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
                "\(TaptionActivityEngineAdapter.trustLabel(for: actual)) · \(actualSourceName(actual.source)) · \(confidenceName(actual.confidence))",
            categoryID: actual.categoryID,
            categoryName: index.categoryNames[actual.categoryID]
        )
    }

    func sensorTimelineBlocks(
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
                        title: MovementPresentation.title(for: travel.mode),
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
                        categoryName: "이동",
                        travelID: travel.id,
                        recordNodeID: "automatic.travel.\(travel.id.uuidString)"
                    )
                }
        case "location":
            let visiblePlaces = PlaceStayPresentationEngine.consolidated(
                model.snapshot.places.compactMap { place in
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
            )
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

    func timelineBlock(
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
        minimumWidth: CGFloat = 18,
        detailText: String? = nil,
        isGoal: Bool = false,
        categoryID: String? = nil,
        categoryName: String? = nil,
        appUsageTokenData: Data? = nil,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        styleKey: String? = nil,
        minimumFraction: CGFloat = 0.012
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
            length: max(minimumFraction, min(1, length)),
            top: top,
            height: height,
            isFixed: isFixed,
            groupCount: groupCount,
            actualFraction: actualFraction,
            status: status,
            isActual: isActual,
            opensLocationTimeline: opensLocationTimeline,
            minimumWidth: minimumWidth,
            startsAt: span.start,
            endsAt: span.end,
            detailText: detailText,
            categoryID: categoryID,
            categoryName: categoryName,
            isGoal: isGoal,
            appUsageTokenData: appUsageTokenData,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: recordNodeID,
            fillColor: fillColor,
            actualColor: actualColor,
            styleKey: styleKey
        )
    }

    func photoRow(_ clusters: [PhotoCluster]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: TaptionSpacing.tight) {
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

    func nearestBlock(
        in blocks: [TimelineBlock],
        to date: Date
    ) -> TimelineBlock? {
        blocks.min { lhs, rhs in
            blockDistance(lhs, to: date) < blockDistance(rhs, to: date)
        }
    }

    func blockDistance(
        _ block: TimelineBlock,
        to date: Date
    ) -> TimeInterval {
        guard let start = block.startsAt, let end = block.endsAt else {
            return .greatestFiniteMagnitude
        }
        if start <= date, date <= end { return 0 }
        return min(abs(start.timeIntervalSince(date)), abs(end.timeIntervalSince(date)))
    }

    func focusOnBlock(_ block: TimelineBlock) {
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

    func selectionFromBlock(_ block: TimelineBlock) -> TimelineSelection {
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
        let actualID = block.actualID ?? (
            block.isActual
                && model.snapshot.actuals.contains(where: { $0.id == block.id })
                ? block.id
                : nil
        )
        let travelID = block.travelID ?? (
            block.categoryID == "movement"
                && model.snapshot.travel.contains(where: { $0.id == block.id })
                ? block.id
                : nil
        )
        return TimelineSelection(
            title: block.title,
            span: selectionSpan,
            planID: block.planID,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: {
                if let recordNodeID = block.recordNodeID {
                    return recordNodeID
                }
                if let travelID {
                    return "automatic.travel.\(travelID.uuidString)"
                }
                if let actualID {
                    return "automatic.actual.\(actualID.uuidString)"
                }
                if block.isActual {
                    if block.categoryID == "location",
                       model.snapshot.places.contains(where: {
                           $0.id == block.id
                       }) {
                        return "automatic.place.\(block.id.uuidString)"
                    }
                    if block.categoryID == "weather",
                       model.snapshot.weather.contains(where: {
                           $0.id == block.id
                       }) {
                        return "automatic.weather.\(block.id.uuidString)"
                    }
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
