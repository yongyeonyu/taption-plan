import SwiftUI
import UIKit
import MapKit

extension TimelineBoard {
    func axis(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            if !usesFullWidthRuler {
                resolutionMenu
                    .frame(width: scheduleLabelColumnWidth)
            }
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
        .overlay(alignment: .leading) {
            if usesFullWidthRuler {
                resolutionMenu
                    .frame(width: scheduleLabelColumnWidth)
                    .background(Color.tpSurface.opacity(0.92), in: Capsule())
            }
        }
        .padding(.horizontal, usesFullWidthRuler ? 0 : 4)
        .frame(height: axisHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func axisMarkerLabel(
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

    func drillDown(from marker: TimelineAxisMarker) {
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

    var resolutionMenu: some View {
        Menu {
            Section("화면 해상도") {
                ForEach(TimelineZoomPreset.scheduleCases) { preset in
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
                                    .accessibilityLabel("선택됨")
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

    var currentResolutionPreset: TimelineZoomPreset {
        TimelineZoomPreset.nearest(
            to: visibleSpan.duration * viewport.length
        )
    }

    var currentResolutionLabel: String {
        TimelineZoomPreset.displayLabel(
            for: visibleSpan.duration * viewport.length
        )
    }

    func selectResolution(_ preset: TimelineZoomPreset) {
        guard preset != .oneYear else { return }
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

    func selectScaleForResolution(_ targetScale: TimeScale) {
        model.selectScale(targetScale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: targetScale)
        continuousTimelineDuration = continuousDuration(around: model.selectedDate)
    }

    var rootTimelinePlans: [PlanRecord] {
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

    func phaseActivityValues(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        phases: [DayPhaseSpan],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelinePhaseActivity] {
        let now = Date.now
        let observed = TimeSpan(
            start: visibleSpan.start,
            end: min(visibleSpan.end, now)
        )
        guard observed.duration > 0 else { return [] }
        var values: [TimelinePhaseActivity] = []

        let sleepRing = RecordClockDetailEngine.activitySleepRing(
            sessions: model.sleepSessions,
            in: observed
        )
        let sleepSpans: [TimeSpan] = sleepRing?.arcs.compactMap { arc in
            let span = TimeSpan(
                start: observed.start.addingTimeInterval(
                    observed.duration * arc.startFraction
                ),
                end: observed.start.addingTimeInterval(
                    observed.duration * arc.endFraction
                )
            )
            guard let stage = SleepStage(rawValue: arc.token) else {
                return nil
            }
            values += assignedPhaseActivities(
                seed: "sleep.\(arc.id)",
                title: stage.displayName,
                span: span,
                phases: phases,
                categoryID: "sleep",
                categoryName: "수면",
                detailText: "Apple 건강 · 수정 불가",
                color: RecordTimelinePalette.detailColor(
                    .sleepStage,
                    token: arc.token
                ),
                isMeasured: true,
                styleKey: "sleep.\(arc.token)"
            )
            return span
        } ?? []

        var travelSpans: [TimeSpan] = []
        var workoutTravelSpans: [TimeSpan] = []
        for segment in travel.sorted(by: { $0.span.start < $1.span.start }) {
            guard let span = segment.span.intersection(with: observed) else {
                continue
            }
            let isWorkout = TravelSegmentPresentationEngine
                .isWorkoutTravel(segment, actuals: actuals, asOf: now)
            if isWorkout {
                workoutTravelSpans.append(span)
            } else {
                travelSpans.append(span)
            }
            values += assignedPhaseActivities(
                seed: "travel.\(segment.id.uuidString)",
                title: MovementPresentation.title(for: segment.mode),
                span: span,
                phases: phases,
                categoryID: isWorkout ? "exercise" : "movement",
                categoryName: isWorkout ? "운동" : "이동",
                detailText: isWorkout
                    ? "운동 기록 · 수정 불가"
                    : "센서 추정 · \(confidenceName(segment.confidence))",
                color: isWorkout
                    ? RecordTimelinePalette.categoryColor("exercise")
                    : RecordTimelinePalette.detailColor(
                        .travel,
                        token: segment.mode.rawValue
                    ),
                isMeasured: true,
                travelID: segment.id,
                recordNodeID: "automatic.travel.\(segment.id.uuidString)",
                isRoute: true,
                styleKey: isWorkout
                    ? "exercise.\(segment.mode.rawValue).workout"
                    : "travel.\(segment.mode.rawValue)"
            )
        }

        var seen = Set<UUID>()
        for actual in actuals where seen.insert(actual.id).inserted {
            guard let span = actual.span(asOf: now).intersection(with: observed)
            else { continue }
            let categoryID = ActualRecordCategoryResolver.categoryID(for: actual)
            let covered: [TimeSpan] = if categoryID == "sleep" {
                sleepSpans
            } else if categoryID == "movement" {
                travelSpans
            } else if categoryID == "exercise",
                      AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) {
                workoutTravelSpans
            } else {
                []
            }
            let color = activityColor(categoryID)
            for remainder in ActualIntervalMergeEngine.subtracting(
                covered,
                from: span
            ) {
                values += assignedPhaseActivities(
                    seed: "actual.\(actual.id.uuidString)",
                    title: activityTitle(actual, categoryID: categoryID),
                    span: remainder,
                    phases: phases,
                    categoryID: categoryID,
                    categoryName: index.categoryNames[categoryID]
                        ?? TimelineRowKind.title(forCategoryID: categoryID)
                        ?? actual.title,
                    detailText:
                        "자동 활동 · \(actualSourceName(actual.source))",
                    color: color,
                    isMeasured: true,
                    actualID: actual.id,
                    isRoute: categoryID == "movement",
                    appUsageTokenData: model.appUsageTokenIndex[actual.id],
                    styleKey: "actual.\(categoryID).\(actual.title)"
                )
            }
        }
        return values
    }

    func assignedPhaseActivities(
        seed: String,
        title: String,
        span: TimeSpan,
        phases: [DayPhaseSpan],
        categoryID: String,
        categoryName: String,
        detailText: String,
        color: Color,
        isMeasured: Bool,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool = false,
        appUsageTokenData: Data? = nil,
        styleKey: String
    ) -> [TimelinePhaseActivity] {
        let activityPhase = DayPhase.phase(forActivityCategory: categoryID)
        return DayPhaseEngine.assignments(of: span, to: phases)
            .filter { $0.phase == activityPhase }
            .map { assignment in
            phaseActivity(
                seed: seed,
                phase: assignment.phase,
                title: title,
                span: assignment.span,
                categoryID: categoryID,
                categoryName: categoryName,
                detailText: detailText,
                color: color,
                isMeasured: isMeasured,
                actualID: actualID,
                travelID: travelID,
                recordNodeID: recordNodeID,
                isRoute: isRoute,
                appUsageTokenData: appUsageTokenData,
                styleKey: styleKey
            )
        }
    }

    func inferredPhaseActivities(
        _ phases: [DayPhaseSpan],
        coveredBy values: [TimelinePhaseActivity]
    ) -> [TimelinePhaseActivity] {
        let byPhase = Dictionary(grouping: values, by: \.phase)
        return phases.flatMap { value -> [TimelinePhaseActivity] in
            let covered = byPhase[value.phase, default: []]
                .compactMap { $0.span.intersection(with: value.span) }
            let fallback = fallbackActivity(for: value.phase)
            return ActualIntervalMergeEngine.subtracting(
                covered,
                from: value.span
            ).map { span in
                phaseActivity(
                    seed: "inferred.\(value.phase.rawValue)",
                    phase: value.phase,
                    title: fallback.title,
                    span: span,
                    categoryID: fallback.categoryID,
                    categoryName: fallback.title,
                    detailText: "일과에서 추정",
                    color: activityColor(fallback.categoryID),
                    styleKey: "inferred.\(fallback.categoryID)"
                )
            }
        }
    }

    func phaseActivity(
        seed: String,
        phase: DayPhase,
        title: String,
        span: TimeSpan,
        categoryID: String,
        categoryName: String,
        detailText: String,
        color: Color,
        isMeasured: Bool = false,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool = false,
        appUsageTokenData: Data? = nil,
        styleKey: String? = nil
    ) -> TimelinePhaseActivity {
        TimelinePhaseActivity(
            id: stablePhaseActivityID(seed, phase: phase, span: span),
            phase: phase,
            title: title,
            span: span,
            categoryID: categoryID,
            categoryName: categoryName,
            detailText: detailText,
            color: color,
            isMeasured: isMeasured,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: recordNodeID,
            isRoute: isRoute,
            appUsageTokenData: appUsageTokenData,
            styleKey: styleKey ?? "\(categoryID).\(title)"
        )
    }

    func dayPhaseSystemImage(_ phase: DayPhase) -> String {
        switch phase {
        case .sleep: "bed.double.fill"
        case .movement: "arrow.left.arrow.right"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .activity: "figure.stand"
        case .appointment: "calendar"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .evening: "fork.knife"
        case .unconfirmed: "questionmark.circle"
        case .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .activityDeparture, .commuteHomeFromWork,
             .commuteHomeFromSchool, .commuteHomeFromAcademy,
             .activityReturn: "arrow.left.arrow.right"
        }
    }

    func dayPhaseColor(_ phase: DayPhase) -> Color {
        RecordTimelinePalette.detailColor(
            .dayPhase,
            token: phase.rawValue
        )
    }

    func activityColor(_ categoryID: String) -> Color {
        let fallback = model.snapshot.categories.first {
            $0.id == categoryID
        }?.actualHex
        return RecordTimelinePalette.categoryColor(
            categoryID,
            fallbackHex: fallback
        )
    }

    func activityTitle(
        _ actual: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement",
           let mode = MovementPresentation.mode(for: actual) {
            return MovementPresentation.title(for: mode)
        }
        return actual.title
    }

    func fallbackActivity(
        for phase: DayPhase
    ) -> (title: String, categoryID: String) {
        switch phase {
        case .sleep: ("수면", "sleep")
        case .movement: ("이동", "movement")
        case .exercise: ("운동", "exercise")
        case .hobby: ("취미", "hobby")
        case .activity: ("활동", "activity")
        case .appointment: ("일정", "calendar")
        case .work: ("업무", "work")
        case .study: ("학업", "study")
        case .evening: ("생활", "activity")
        case .unconfirmed: ("미확인", "unconfirmed")
        case .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .activityDeparture, .commuteHomeFromWork,
             .commuteHomeFromSchool, .commuteHomeFromAcademy,
             .activityReturn: ("이동", "movement")
        }
    }

    func stablePhaseActivityID(
        _ seed: String,
        phase: DayPhase,
        span: TimeSpan
    ) -> UUID {
        let value = [
            seed,
            phase.rawValue,
            String(Int(span.start.timeIntervalSinceReferenceDate.rounded())),
            String(Int(span.end.timeIntervalSinceReferenceDate.rounded())),
        ].joined(separator: "|")
        return StableRecordID.foldedFNV(value)
    }

    func appUsageDetailText(_ actual: ActualRecord) -> String {
        guard let duration = ScreenTimeUsageRecordEngine
            .durationText(actual.span().duration) else {
            return actualSourceName(actual.source)
        }
        return "\(duration) · \(actualSourceName(actual.source))"
    }

    func compactAutomaticTop(_ lane: Int) -> CGFloat {
        5 + CGFloat(lane) * 18
    }

    func calendarDetailText(_ event: CalendarRecord) -> String {
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

    func isGoalPlan(_ plan: PlanRecord) -> Bool {
        // Only an explicit goal or a generated repeat segment gets goal
        // styling. A regular plan having child items is still a plan; the
        // mere existence of descendants must not invent a goal in details.
        if plan.origin == .repeatRule {
            return true
        }
        return GoalRecordPolicy.isGoal(plan)
    }

    func goalDisplayTitle(_ title: String) -> String {
        GoalRecordPolicy.displayTitle(title)
    }

    func confidenceName(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    func actualSourceName(_ source: ActualSource) -> String {
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

    var isContinuousDay: Bool {
        scale == .day
    }

    /// Every schedule resolution now uses the same continuous NLE playhead
    /// model. Day keeps its selected zoom duration; week and month retain the
    /// calendar period's initial width while the center moves through adjacent
    /// periods.
    var isContinuousTimeline: Bool {
        switch scale {
        case .day, .week, .month:
            true
        case .year:
            false
        }
    }

    func continuousDuration(around date: Date) -> TimeInterval {
        if scale == .day {
            return max(60, dayZoom.duration)
        }
        return max(
            86_400,
            TimelineAxisGrid.span(for: scale, containing: date).duration
        )
    }

    var activeContinuousDuration: TimeInterval {
        return max(
            60,
            continuousTimelineDuration > 0
                ? continuousTimelineDuration
                : continuousDuration(around: continuousCenterDate)
        )
    }

    var hasCustomContinuousDuration: Bool {
        let standard = continuousDuration(around: continuousCenterDate)
        return abs(activeContinuousDuration - standard) > 1
    }

    func timelineFraction(
        of date: Date,
        in span: TimeSpan
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        return date.timeIntervalSince(span.start) / span.duration
    }

    func timelineDate(
        at fraction: Double,
        in span: TimeSpan
    ) -> Date {
        span.start.addingTimeInterval(
            span.duration * min(1, max(0, fraction))
        )
    }

    var standardVisibleSpan: TimeSpan {
        TimelineAxisGrid.span(
            for: scale,
            containing: model.selectedDate
        )
    }

    var visibleSpan: TimeSpan {
        guard isContinuousTimeline else { return standardVisibleSpan }
        return NLETimelineViewport(
            centerDate: continuousCenterDate,
            visibleDuration: activeContinuousDuration
        ).span
    }

    @ViewBuilder
    func currentLine() -> some View {
        if isContinuousTimeline {
            GeometryReader { proxy in
                let leadingWidth = usesFullWidthRuler
                    ? 0
                    : scheduleLabelColumnWidth
                let x = leadingWidth
                    + max(1, proxy.size.width - leadingWidth) / 2
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
                let leadingWidth = usesFullWidthRuler
                    ? 0
                    : scheduleLabelColumnWidth
                let timelineWidth = max(
                    1,
                    proxy.size.width - leadingWidth
                )
                let x = leadingWidth + timelineWidth / 2
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

    func photoMarker(
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
                        .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
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

    func photoMarkerX(
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

    func summaryStrip(
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

    var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월·주·일 요약"
        }
    }

    func summaryColors(
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

    func nowFraction(at date: Date) -> CGFloat {
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

    var viewportMinimumLength: Double {
        GanttViewport.oneMinuteMinimumLength(
            for: visibleSpan.duration
        )
    }

    var viewportVisibleSpan: TimeSpan {
        TimeSpan(
            start: timelineDate(at: viewport.start, in: visibleSpan),
            end: timelineDate(at: viewport.end, in: visibleSpan)
        )
    }

    func axisMarkers(in visibleSpan: TimeSpan) -> [TimelineAxisMarker] {
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
}
