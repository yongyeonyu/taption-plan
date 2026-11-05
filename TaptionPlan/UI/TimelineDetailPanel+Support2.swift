import SwiftUI
import UIKit
import MapKit

extension TimelineDetailPanel {
    func goalForActual(_ actual: ActualRecord) -> PlanRecord? {
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

    var activeActionPlans: [PlanRecord] {
        detailData.actionPlans
    }

    func isManualActionPlan(_ plan: PlanRecord) -> Bool {
        plan.categoryID != "event"
            && !automaticDetailCategoryIDs.contains(plan.categoryID)
            && !GoalRecordPolicy.isGoal(plan)
    }

    var selectedManualActionPlan: PlanRecord? {
        detailData.selectedManualActionPlan
    }

    var detailPlaces: [PlaceStay] {
        detailData.places
    }

    var detailTravel: [TravelSegment] {
        detailData.travel
    }

    var detailMovementActuals: [ActualRecord] {
        detailData.movementActuals
    }

    var confirmedDetailTravel: [TravelSegment] {
        detailTravel.filter { $0.isConfirmed || $0.confidence != .low }
    }

    var confirmedDetailMovementActuals: [ActualRecord] {
        detailMovementActuals.filter(isConfirmedMovementActual)
    }

    var detailSleepPlans: [PlanRecord] {
        detailData.sleepPlans
    }

    var detailActivityPlans: [PlanRecord] {
        detailData.activityPlans
    }

    var detailSleepActuals: [ActualRecord] {
        detailData.sleepActuals
    }

    var detailActivityActuals: [ActualRecord] {
        detailData.activityActuals
    }

    var detailAppUsageActuals: [ActualRecord] {
        detailData.appUsageActuals
    }

    var detailData: TimelineDetailDataCache.Value {
        let contentSpan = detailContentSpan
        let displaySpan = detailDisplaySpan
        let selection = activeSelection
        let cacheSpan = selection?.span ?? contentSpan
        let memoSpan = detailMemoSpan
        let key = TimelineDetailDataCache.Key(
            timelineRevision: model.timelineRevision,
            contentStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            contentEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            displayStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            displayEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            memoStart: memoSpan.start.timeIntervalSinceReferenceDate,
            memoEnd: memoSpan.end.timeIntervalSinceReferenceDate,
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
            let places = PlaceStayPresentationEngine.consolidated(
                playheadMatch?.places ?? model.snapshot.places.filter {
                    $0.span.intersection(with: focusedSpan) != nil
                }
            )
            let travel = TravelSegmentPresentationEngine.consolidated(
                playheadMatch?.travel ?? model.snapshot.travel.filter {
                    $0.span.intersection(with: focusedSpan) != nil
                }
            )
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
            let reviewedAutomaticActuals = MovementDisplayEngine.reviewActuals(
                automaticActuals,
                travel: travel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: .now
            )
            let displayedAutomaticActuals = RestSleepDisplayEngine
                .visibleActuals(
                    reviewedAutomaticActuals,
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
                calendarEvents: calendarEvents,
                memos: MemoTimelineEngine.detailList(
                    in: memoSpan,
                    from: model.snapshot.memos
                )
            )
        }
    }

    /// 메모 카드와 메모 알약이 읽는 구간. 시간표가 펼쳐 둔 기간을 그대로
    /// 본다. 다른 줄은 재생 머리가 짚은 순간에 걸친 기록만 골라내지만
    /// 메모는 길이가 없는 순간이라 그 방식으로는 영영 걸리지 않는다.
    /// 시간표 메모 줄에 표식이 보이면 알약도 함께 나오는 것이 규칙이다.
    var detailMemoSpan: TimeSpan {
        Self.periodEngine.interval(
            for: model.selectedScale.timelineLevel,
            containing: model.selectedDate
        )
    }

    func deduplicatedPlans(
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

    func deduplicatedActuals(
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

    func actualSourcePriority(_ source: ActualSource) -> Int {
        switch source {
        case .healthKit, .appleWatch, .motion, .media, .call, .appUsage: 3
        case .location: 2
        case .timer, .manual: 1
        case .calendar, .photo: 0
        }
    }

    var detailContentSpan: TimeSpan {
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

    var detailDisplaySpan: TimeSpan {
        if playheadDate != nil || activeSelection != nil {
            return detailContentSpan
        }
        return daySpan
    }

    var hasScheduleContent: Bool {
        !detailData.calendarEvents.isEmpty
    }

    var hasLocationContent: Bool {
        !detailPlaces.isEmpty
            || (playheadDate == nil
                && activeSelection == nil
                && currentLocationCoordinate != nil)
    }

    var hasMovementContent: Bool {
        !confirmedDetailTravel.isEmpty || !confirmedDetailMovementActuals.isEmpty
    }

    var hasSleepContent: Bool {
        !detailSleepPlans.isEmpty || !detailSleepActuals.isEmpty
    }

    var hasActivityContent: Bool {
        !detailActivityPlans.isEmpty || !detailActivityActuals.isEmpty
    }

    var hasAppUsageContent: Bool {
        !detailAppUsageActuals.isEmpty
    }

    var hasWeatherContent: Bool {
        !detailData.weather.isEmpty
    }

    /// 다른 줄과 같은 규칙이다. 보고 있는 기간에 메모가 하나라도 있으면
    /// 알약과 카드가 함께 나오고, 없으면 함께 빠진다.
    var hasMemoContent: Bool {
        !detailData.memos.isEmpty
    }

    var hasRoutineContent: Bool {
        focusedRoutineForDetail != nil
    }

    var hasActionContent: Bool {
        if let actual = selectedActual {
            return !isSleepActual(actual) && actual.categoryID != "activity"
        }
        return !activeActionPlans.isEmpty
    }

    var hasEventContent: Bool {
        !detailData.eventPlans.isEmpty
    }

    func isSleepActual(_ actual: ActualRecord) -> Bool {
        AutomaticRecordTimelineEngine.isSleep(actual)
    }

    func actionPlanTimeLabel(_ plan: PlanRecord) -> String {
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

    var selectedActual: ActualRecord? {
        detailData.selectedActual
    }

    func actualSourceLabel(_ source: ActualSource) -> String {
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

    func confidenceLabel(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    func placeTitle(_ place: PlaceStay) -> String {
        if let floor = place.floor {
            return place.displayName + " · " + String(floor) + "층"
        }
        return place.displayName
    }

    func travelPlaceTitle(_ placeID: UUID?) -> String? {
        guard let placeID else { return nil }
        return (detailPlaces + model.snapshot.places)
            .first { $0.id == placeID }
            .map(placeTitle)
    }

    func travelLocationLabel(_ travel: TravelSegment) -> String? {
        if let stationRoute = travel.evidence.first(where: {
            $0.hasPrefix("지하철역 ")
        }) {
            return stationRoute
        }
        let from = travelPlaceTitle(travel.fromPlaceID)
        let to = travelPlaceTitle(travel.toPlaceID)
        switch (from, to) {
        case let (from?, to?): return from + " → " + to
        case let (from?, nil): return from + " → 위치 미확인"
        case let (nil, to?): return "위치 미확인 → " + to
        case (nil, nil): return nil
        }
    }

    func distanceLabel(_ meters: Double) -> String {
        AppRegion.current.distanceText(meters: meters, compact: true)
    }

    func actionMemoPreview(planID: UUID) -> some View {
        let memos = model.memos(for: planID)
        return VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.compact) {
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
            in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
        }
    }

    var eventContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
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
            Text("애플·구글·네이버 캘린더에서 가져온 내용은 ‘일정’ 카드에 표시됩니다.")
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    var photoContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
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
                    in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous))

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

    var scheduleContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("일정", systemImage: "calendar")
            let calendarEvents = detailData.calendarEvents
            if calendarEvents.isEmpty {
                Text("이날 등록된 일정이 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(calendarEvents) { event in
                    HStack(spacing: TaptionSpacing.cozy) {
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

    func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    func calendarDateLabel(_ date: Date) -> String {
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

    func calendarSourceLabel(for event: CalendarRecord) -> String {
        let source = event.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = event.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty, source != calendar {
            return "\(source) · \(calendar)"
        }
        return calendar.isEmpty ? "캘린더" : calendar
    }

    func detailHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.taption(size: 10, weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(for: .day, containing: model.selectedDate)
    }

    var activeRouteSpan: TimeSpan {
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

    var activePhotoCluster: PhotoCluster? {
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

    var photoDetailTolerance: TimeInterval {
        60
    }

    var routeTitle: String {
        if playheadDate != nil,
           routeSegments.isEmpty,
           fallbackRouteCoordinates.count < 2,
           !hasDimmedRoutes {
            return "현재 위치"
        }
        // 지도가 기간 전체의 지난 경로를 담고 있으면 제목도 그 기간을
        // 말해야 한다. 년 눈금은 배경을 깔지 않아 예전 이름을 그대로 쓴다.
        if let period = routePeriodName, !contextRouteSegments.isEmpty {
            if playheadDate != nil {
                return "\(period) 이동 경로 · 현재 구간"
            }
            if activeSelection?.isRoute == true {
                return "\(period) 이동 경로 · 선택 구간"
            }
            return "\(period) 이동 경로"
        }
        if playheadDate != nil {
            return "현재 이동 경로"
        }
        if activeSelection?.isRoute == true {
            return "선택된 이동 경로"
        }
        if activeSelection != nil {
            return "선택된 시간 경로"
        }
        return "오늘 이동 경로"
    }

    var routeSegments: [TravelSegment] {
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

    var routeReadingsSignature: TimelineRouteReadingSignature {
        TimelineRouteReadingSignature(
            count: routeReadings.count,
            firstID: routeReadings.first?.id,
            lastID: routeReadings.last?.id,
            firstTimestamp: routeReadings.first?.timestamp,
            lastTimestamp: routeReadings.last?.timestamp
        )
    }

    var explicitlySelectedTravel: TravelSegment? {
        guard playheadDate == nil, let travelID = activeSelection?.travelID else {
            return nil
        }
        return model.snapshot.travel.first { $0.id == travelID }
    }

    var selectedSegmentIDs: Set<UUID> {
        guard let selection = activeSelection, selection.isRoute else {
            return Set(routeSegments.map(\.id))
        }
        return Set(routeSegments.filter {
            $0.span.intersection(with: selection.span) != nil
        }.map(\.id))
    }

    var selectedSegment: TravelSegment? {
        guard let selection = activeSelection, selection.isRoute else { return nil }
        return routeSegments.first {
            $0.span.intersection(with: selection.span) != nil
        }
    }

    /// 지도에 함께 깔 기간. 시간표가 보여 주는 기간과 같다.
    var routeContextSpan: TimeSpan? {
        TimelineRouteDisplayPolicy.contextSpan(
            for: model.selectedScale.timelineLevel,
            visibleSpan: TimelineAggregationEngine().interval(
                for: model.selectedScale.timelineLevel,
                containing: model.selectedDate
            )
        )
    }

    var contextRouteSegments: [TravelSegment] {
        guard let span = routeContextSpan else { return [] }
        return routePresentationCache.contextSegments(
            for: routePresentationCacheKey,
            span: span
        ) {
            TimelineRouteDisplayPolicy.contextSegments(
                from: model.snapshot.travel,
                intersecting: span
            )
        }
    }

    var dimmedRouteSegments: [TravelSegment] {
        guard !contextRouteSegments.isEmpty else { return [] }
        let highlighted = Set(routeSegments.map(\.id))
        return contextRouteSegments.filter { !highlighted.contains($0.id) }
    }

    var hasDimmedRoutes: Bool {
        !dimmedRouteSegments.isEmpty
    }

    var routePeriodName: String? {
        guard routeContextSpan != nil else { return nil }
        switch model.selectedScale {
        case .day: return "하루"
        case .week: return "한 주"
        case .month: return "한 달"
        case .year: return nil
        }
    }

    /// 옅게 깔린 경로를 눌러도 그 구간이 고른 구간이 된다. 시간표 막대를
    /// 누른 것과 같은 선택을 만들어 올려 보내므로 선택 경로는 하나뿐이다.
    func selectRouteSegment(near coordinate: CLLocationCoordinate2D) {
        guard let region = visibleMapRegion else { return }
        // 손가락 하나가 닿는 넓이를 지금 배율의 거리로 바꾼다.
        let metersPerPoint = region.span.latitudeDelta
            * 111_320
            / Double(max(1, routeMapHeight))
        let toleranceMeters = max(12, metersPerPoint * 22)
        var best: (segment: TravelSegment, distance: Double)?
        for segment in dimmedRouteSegments {
            let values = coordinates(for: segment)
            guard values.count >= 2,
                  let distance = RoutePolylineDecimator.distanceMeters(
                      from: coordinate,
                      to: values
                  ),
                  distance <= toleranceMeters else { continue }
            if best.map({ distance < $0.distance }) ?? true {
                best = (segment, distance)
            }
        }
        guard let picked = best?.segment else { return }
        onRouteSelection(
            TimelineSelection(
                title: MovementPresentation.title(for: picked.mode),
                span: picked.span,
                planID: nil,
                travelID: picked.id,
                recordNodeID: "automatic.travel.\(picked.id.uuidString)",
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        )
    }

    struct RouteLocationPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String
        let tint: Color
    }

    var routeLocationPins: [RouteLocationPin] {
        if playheadDate != nil && routeSegments.isEmpty {
            return []
        }

        var pins: [RouteLocationPin] = []
        var usedPlaceIDs = Set<UUID>()
        var usedStationKeys = Set<String>()
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

            if segment.mode == .subway, let route = segment.subwayRoute {
                for stop in route.stops {
                    guard let point = stop.coordinate,
                          isValidCoordinate(point),
                          usedStationKeys.insert(stop.stationName).inserted else {
                        continue
                    }
                    pins.append(
                        RouteLocationPin(
                            id: "\(segment.id)-station-\(stop.stationName)",
                            coordinate: CLLocationCoordinate2D(
                                latitude: point.latitude,
                                longitude: point.longitude
                            ),
                            title: "\(stop.stationName)역 · \(stop.lineName)",
                            tint: routeColor(for: segment.mode)
                        )
                    )
                }
            }
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

    var playheadRoutePin: RouteLocationPin? {
        guard let coordinate = playheadFocusCoordinate else { return nil }
        return RouteLocationPin(
            id: "playhead-focus",
            coordinate: coordinate,
            title: "현재 위치",
            tint: .tpNow
        )
    }

    var allowsFallbackRoutePath: Bool {
        TimelineRouteDisplayPolicy.allowsFallbackPath(
            at: playheadDate,
            routeSegments: routeSegments
        ) || fallbackRouteCoordinates.count >= 2
    }

    var shouldDrawFallbackRoutePath: Bool {
        guard allowsFallbackRoutePath,
              fallbackRouteCoordinates.count >= 2 else {
            return false
        }
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        return routeSegments.isEmpty || segmentCoordinates.count < 2
    }
}
