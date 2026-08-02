import Foundation

enum TaptionWidgetPayloadFactory {
    static func make(
        from snapshot: TaptionDataSnapshot,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TaptionWidgetPayload {
        let dayStart = calendar.startOfDay(for: now)
        let widgetStart = calendar.date(
            byAdding: .day,
            value: -1,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-86_400)
        let widgetEnd = calendar.date(
            byAdding: .day,
            value: 8,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(8 * 86_400)
        let widgetSpan = TimeSpan(start: widgetStart, end: widgetEnd)
        let categoriesByID = Dictionary(
            snapshot.categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Goals are containers, not executable timeline items. Including a
        // root goal together with its generated/repeating child made the
        // widget draw two bars in the same action lane, which looked like an
        // overlapping duplicate. The widget should show only actionable
        // plans; the goal dashboard remains the place for goal summaries.
        let planItems = snapshot.plans
            .filter { $0.status != .completed && $0.status != .skipped }
            .filter { !GoalRecordPolicy.isGoal($0) }
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = categoriesByID[plan.categoryID]
                return TaptionWidgetItem(
                    id: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startsAt: plan.span.start,
                    endsAt: plan.span.end,
                    status: plan.status.rawValue,
                    isFixed: plan.isFixed,
                    categoryName: category?.name,
                    categoryHex: category?.lightHex,
                    lane: .action
                )
            }

        let calendarItems = snapshot.calendarEvents
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { event in
                TaptionWidgetItem(
                    id: UUID(uuidString: event.id) ?? UUID(),
                    title: event.title,
                    categoryID: "calendar",
                    startsAt: event.span.start,
                    endsAt: event.span.end,
                    status: PlanStatus.planned.rawValue,
                    isFixed: true,
                    categoryName: "캘린더",
                    categoryHex: "#BEDAE3",
                    lane: .schedule
                )
            }

        let locationItems = snapshot.places
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { place in
                TaptionWidgetItem(
                    id: place.id,
                    title: TaptionWidgetContentPolicy.locationTitle(
                        displayName: place.displayName,
                        floor: place.floor
                    ),
                    categoryID: "location",
                    startsAt: place.span.start,
                    endsAt: place.span.end,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "위치",
                    categoryHex: "#BEDAE3",
                    lane: .location
                )
            }

        let movementItems = snapshot.travel
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { travel in
                TaptionWidgetItem(
                    id: travel.id,
                    title: travelModeName(travel.mode),
                    categoryID: "movement",
                    startsAt: travel.span.start,
                    endsAt: travel.span.end,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "이동",
                    categoryHex: "#D2AE76",
                    lane: .movement
                )
            }

        let automaticHealthItems = AutomaticRecordTimelineEngine.activities(
            from: snapshot.actuals,
            inside: widgetSpan
        )
        let sleepItems = automaticHealthItems
            .filter(AutomaticRecordTimelineEngine.isSleep)
            .map { actual in
                TaptionWidgetItem(
                    id: actual.id,
                    title: actual.title,
                    categoryID: "sleep",
                    startsAt: actual.startedAt,
                    endsAt: actual.endedAt ?? now,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "수면",
                    categoryHex: "#C9D6E5",
                    lane: .sleep
                )
            }
        let activityItems = automaticHealthItems
            .filter { !AutomaticRecordTimelineEngine.isSleep($0) }
            .map { actual in
                TaptionWidgetItem(
                    id: actual.id,
                    title: actual.title,
                    categoryID: actual.categoryID,
                    startsAt: actual.startedAt,
                    endsAt: actual.endedAt ?? now,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "활동",
                    categoryHex: "#7CA980",
                    lane: .activity
                )
            }

        let weather = snapshot.weather.min {
            abs($0.observedAt.timeIntervalSince(now))
                < abs($1.observedAt.timeIntervalSince(now))
        }
        let items = (
            planItems
                + calendarItems
                + locationItems
                + movementItems
                + sleepItems
                + activityItems
        )
        .sorted { $0.startsAt < $1.startsAt }

        return TaptionWidgetPayload(
            generatedAt: now,
            sourceSnapshotUpdatedAt: snapshot.updatedAt,
            sourceFingerprint: TaptionWidgetSyncFingerprint.make(items: items),
            viewportStart: widgetStart,
            viewportEnd: widgetEnd,
            displayCenterDate: now,
            displayDuration: TaptionWidgetPlaybackEngine.defaultWindowDuration,
            displayResolutionLabel: TaptionWidgetPlaybackEngine.defaultResolutionLabel,
            items: items,
            catStyle: snapshot.settings.catStyle.rawValue,
            hidesSensitiveContent: false,
            weatherSymbolName: weather?.symbolName,
            temperatureCelsius: weather?.temperatureCelsius,
            reducesMotion: snapshot.settings.reduceMotion
        )
    }

    private static func travelModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자가용"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }
}
