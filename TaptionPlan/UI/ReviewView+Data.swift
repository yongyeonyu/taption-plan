import Charts
import SwiftUI

extension ReviewView {
    // MARK: - 데이터

    var contentKey: ReviewContentKey {
        ReviewContentKey(
            revision: model.timelineRevision,
            scale: model.reviewScale,
            date: model.selectedDate,
            selectedBucketIDs: selectedBucketIDs,
            selectedChartBucketID: selectedChartBucketID,
            healthRefreshedAt: model.lastHealthRefreshAt
        )
    }

    func rebuildContent() {
        let engine = ReviewEngine()
        let now = Date.now
        // 화면(원형·막대·목록)과 합계가 모두 이 한 값을 읽는다. 수면과 겹친
        // 휴식·생활을 여기서 한 번만 덜어 내야 보이는 시간과 합계가 맞는다.
        let actuals = RestSleepDisplayEngine.visibleActuals(
            MovementDisplayEngine.reviewActuals(
                model.snapshot.actuals,
                travel: model.snapshot.travel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: now
            ),
            asOf: now
        )
        let level = model.reviewScale.timelineLevel
        let period = engine.aggregation.interval(
            for: level,
            containing: model.selectedDate
        )
        let pickable = ReviewSelectionEngine.buckets(
            for: level,
            in: period,
            calendar: engine.aggregation.calendar
        )
        // 다른 기간의 칸을 고른 채로 넘어왔다면 버린다. 남은 칸이 없으면
        // 아래에서 기간 전체로 돌아간다.
        let selected = selectedBucketIDs.intersection(
            Set(pickable.map(\.id))
        )
        if selected != selectedBucketIDs { selectedBucketIDs = selected }

        let phaseActuals = DayPhaseEvidenceEngine.records(
            from: model.snapshot.actuals,
            intersecting: period,
            asOf: now
        )
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let chartBuckets = model.reviewScale == .day
            ? []
            : RecordChartEngine.phaseBuckets(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: period,
                unit: model.reviewScale == .year ? .month : .day,
                calendar: engine.aggregation.calendar,
                asOf: now,
                scope: .canonical
            )
        let selectedChartSpan = ReviewSelectionEngine.chartSpan(
            selectedChartBucketID,
            buckets: chartBuckets
        )
        if selectedChartBucketID != nil, selectedChartSpan == nil {
            selectedChartBucketID = nil
        }

        // 막대를 직접 골랐으면 그 하루·월이 헤더의 큰 구간 선택보다 우선한다.
        let bucketSpans = ReviewSelectionEngine.spans(
            period: period,
            buckets: pickable,
            selectedIDs: selected
        )
        let spans = selectedChartSpan.map { [$0] } ?? bucketSpans
        let displayActuals = ReviewCoverageEngine.records(
            actuals: actuals,
            in: spans,
            asOf: now
        )
        let report = engine.report(
            over: spans,
            plans: model.snapshot.plans,
            actuals: displayActuals,
            weather: model.snapshot.weather,
            photos: model.snapshot.photos,
            memos: model.snapshot.memos,
            asOf: now,
            scope: .canonical
        )

        var rings: [RecordClockRing] = []
        var phaseRing: RecordClockDetailRing?
        var activityRings: [RecordClockDetailRing] = []
        var contextRings: [RecordClockDetailRing] = []
        var phaseGroups: [RecordCategoryGroup] = []
        var phaseDurations = RecordChartEngine.categoryDurations(
            in: chartBuckets
        )
        var selectedChartBucketIDs: Set<String> = []
        if model.reviewScale == .day, let day = spans.first {
            rings = RecordChartEngine.clockRings(
                actuals: displayActuals,
                in: day,
                asOf: now,
                scope: .canonical
            )
            let dayPhases = DayPhaseEngine.completePhases(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: day,
                asOf: now
            )
            phaseDurations = DayPhaseEngine.categoryDurations(
                dayPhases,
                scope: .canonical
            )
            phaseRing = RecordClockDetailEngine.phaseRing(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: day,
                asOf: now,
                scope: .canonical
            )
            phaseGroups = ActualRecordGroupingEngine.phaseGroups(
                phases: dayPhases,
                actuals: displayActuals,
                categories: model.snapshot.categories,
                asOf: now,
                scope: .canonical
            )
            activityRings = RecordClockDetailEngine.activityRings(
                sleepSessions: model.sleepSessions,
                travel: model.snapshot.travel,
                in: day,
                scope: .canonical
            )
            contextRings = [
                RecordClockDetailEngine.weatherRing(
                    contexts: model.snapshot.weather,
                    in: day,
                    asOf: now
                ),
                RecordClockDetailEngine.locationRing(
                    stays: model.snapshot.places,
                    in: day,
                    asOf: now
                ),
            ].compactMap { $0 }
        } else if model.reviewScale == .week {
            // 주 보기 역시 하루 단위로 완성한 일과를 부모로 사용한다.
            // 선택한 날짜가 있으면 그 날짜만, 없으면 주 전체를 계층으로 묶는다.
            let phases = spans.flatMap { span in
                DayPhaseEngine.completePhasesAcrossDays(
                    actuals: phaseActuals,
                    travel: model.snapshot.travel,
                    stays: model.snapshot.places,
                    placeKinds: placeKinds,
                    in: span,
                    calendar: engine.aggregation.calendar,
                    asOf: now
                )
            }
                phaseGroups = ActualRecordGroupingEngine.phaseGroups(
                    phases: phases,
                    actuals: displayActuals,
                    categories: model.snapshot.categories,
                    asOf: now,
                    scope: .canonical
                )
            if let selectedChartBucketID, selectedChartSpan != nil {
                selectedChartBucketIDs = [selectedChartBucketID]
            } else if !selected.isEmpty {
                selectedChartBucketIDs = Set(
                    chartBuckets
                        .filter { bucket in
                            spans.contains {
                                $0.intersection(with: bucket.span) != nil
                            }
                        }
                        .map(\.id)
                )
            }
        } else {
            if let selectedChartBucketID, selectedChartSpan != nil {
                selectedChartBucketIDs = [selectedChartBucketID]
            } else if !selected.isEmpty {
                selectedChartBucketIDs = Set(
                    chartBuckets
                        .filter { bucket in
                            spans.contains {
                                $0.intersection(with: bucket.span) != nil
                            }
                        }
                        .map(\.id)
                )
            }
        }

        // 보고 있는 기간이 바뀌면 재생하던 하루와 수동 위치가 사라진다.
        if content.period != period {
            clearManualPlayhead()
        }
        if content.period != period || model.reviewScale != .day {
            playStartedAt = nil
        }
        let groups = ActualRecordGroupingEngine.groups(
            actuals: displayActuals,
            in: spans,
            categories: model.snapshot.categories,
            asOf: now,
            scope: .canonical
        )
        let hierarchyGroups = model.reviewScale == .day || model.reviewScale == .week
            ? phaseGroups
            : groups
        let groupIDs = Set(hierarchyGroups.map(\.id))
        let collapsesAllGroups = content.spans.isEmpty
            || content.period != period
        content = ReviewContent(
            period: period,
            spans: spans,
            pickableBuckets: pickable,
            selectedBucketCount: selectedChartSpan == nil ? selected.count : 1,
            plannedCategories: report.categories,
            contexts: report.contexts,
            groups: groups,
            displayActuals: displayActuals,
            phaseGroups: phaseGroups,
            rings: rings,
            phaseRing: phaseRing,
            activityRings: activityRings,
            contextRings: contextRings,
            phaseDurations: phaseDurations,
            chartBuckets: chartBuckets,
            selectedChartBucketIDs: selectedChartBucketIDs
        )
        collapsedGroupIDs = collapsesAllGroups
            ? groupIDs
            : collapsedGroupIDs.intersection(groupIDs)
        let legendIDs = model.reviewScale == .day
            ? Set(groups.map(\.id))
            : Set(phaseDurations.map(\.categoryID))
        switch clockHighlight {
        case .phase(let arcID, let token):
            if phaseRing?.arcs.contains(where: {
                $0.id == arcID && $0.token == token
            }) != true {
                clearClockHighlight()
            }
        case .category(let id):
            if !legendIDs.contains(id) { clearClockHighlight() }
        case .detail(let selection):
            if !activityRings.contains(where: {
                $0.kind == selection.kind
                    && $0.arcs.contains(where: { $0.token == selection.token })
            }) {
                clearClockHighlight()
            }
        case nil:
            break
        }
    }

    // MARK: - 표기

    func periodText(_ span: TimeSpan) -> String {
        let period = span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
        guard content.selectedBucketCount > 0 else { return period }
        return "\(period) · \(content.selectedBucketCount)칸"
    }

    func categoryName(_ id: String) -> String {
        if id == ReviewCoverageEngine.unconfirmedCategoryID { return "미확인" }
        return model.snapshot.categories.first { $0.id == id }?.name
            ?? TimelineRowKind.title(forCategoryID: id)
            ?? PlanCategory(categoryID: id).rawValue
    }

    func symbolName(_ group: RecordCategoryGroup) -> String {
        if group.id == ReviewCoverageEngine.unconfirmedCategoryID {
            return "questionmark.circle"
        }
        return TimelineRowKind(categoryID: group.id)?.systemImage
            ?? group.icon?.systemImage
            ?? PlanCategory(categoryID: group.id).systemImage
    }

    func color(forCategoryID id: String) -> Color {
        RecordTimelinePalette.categoryColor(
            id,
            fallbackHex: content.groups.first { $0.id == id }?.colorHex
        )
    }
}
