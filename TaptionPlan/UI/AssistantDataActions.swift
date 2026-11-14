import Foundation
import MapKit
import TaptionPlanCore

/// 폐기됐거나 모르는 연결 키가 보낸 명령은 반영하지 않는다(SEC1110A02).
enum AssistantKeyFilter {
    static func split(_ batch: AssistantCommandBatch, active: Set<String>) -> (kept: AssistantCommandBatch, inactiveIDs: [String]) {
        let kept = batch.commands.filter { isAllowed($0, active: active) }
        let inactive = batch.commands.filter { !isAllowed($0, active: active) }.map(\.id)
        return (AssistantCommandBatch(commands: kept, invalidIDs: batch.invalidIDs, invalidInfo: batch.invalidInfo), inactive)
    }

    /// 살아 있는 연결이 보낸 것, 그리고 서버가 예전 큐에서 옮긴 것(`legacy`, 연결 id 없음)만 받는다.
    /// 주 키로 보낸 것(`master`)은 연결이 아니라 받지 않는다.
    static func isAllowed(_ command: AssistantCommand, active: Set<String>) -> Bool {
        if let keyID = command.keyID { return active.contains(keyID) }
        return command.source == "legacy"
    }

    static func activeIDs(_ keys: [AssistantScopedKey], now: Date = .now) -> Set<String> {
        Set(keys.filter { $0.isActive(now: now) }.map(\.id))
    }
}

/// 「AI가 한 일」에 보일 연결 이름. 키를 나중에 폐기해도 남도록 반영할 때 적어 둔다.
enum AssistantConnectionName {
    static func name(keyID: String?, source: String?, defaults: UserDefaults = .standard) -> String? {
        if let keyID {
            if let label = AssistantKeyLabels.label(keyID, defaults: defaults) { return label }
            if let provider = AssistantKeyProviders.provider(keyID, defaults: defaults) { return provider.title(.current) }
            if let client = AssistantKeyLabels.client(keyID, defaults: defaults) { return client }
        }
        return fallback(source)
    }

    /// 예전 기록은 방식 이름(「OAuth」)만 적혀 있다. 그 연결의 AI 이름을 이제 알면 그것으로 보인다(AIN1114A01).
    static func shown(_ entry: AssistantLogEntry, defaults: UserDefaults = .standard) -> String? {
        guard let stored = entry.connection else { return nil }
        guard ["OAuth", "MCP", "REST"].contains(stored) else { return stored }
        return name(keyID: entry.keyID, source: nil, defaults: defaults) ?? stored
    }

    private static func fallback(_ source: String?) -> String? {
        switch source {
        case "oauth": return "OAuth"
        case "mcp": return "MCP"
        case "rest": return "REST"
        default: return nil
        }
    }
}

/// 루틴·여행·수면·설정 명령을 앱의 기존 편집 경로로 반영한다(AIR1110A03).
/// 기록은 교정표로만 고쳐 자동 원본과 센서 원본은 그대로 둔다.
extension AppModel {
    func applyAssistantDataAction(_ action: AssistantCommand.Action, preferences: AssistantPreferenceStore) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        switch action {
        case let .addGoal(title, start, end, categoryID):
            if let categoryID, !isAssistantCategory(categoryID) { return .rejected("unknown_category") }
            let finish = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
            guard let id = addPlan(
                title: GoalRecordPolicy.displayTitle(title), categoryID: categoryID ?? "activity",
                startAt: start, duration: finish.timeIntervalSince(start)
            ), let plan = snapshot.plans.first(where: { $0.id == id }) else { return .rejected("goal_failed") }
            return AssistantEditResult(after: AssistantDataText.goal(plan))
        case let .updateGoal(goalID, title, start, end, categoryID):
            return updateAssistantGoal(goalID, title: title, start: start, end: end, categoryID: categoryID)
        case let .deleteGoal(goalID):
            guard let goal = assistantGoal(goalID) else { return .rejected("no_goal") }
            let descendants = (try? PlanHierarchy.descendants(of: goal.id, in: snapshot.plans)) ?? []
            // 하위가 너무 많은 루틴은 앱에서 직접 지운다. 하위 수는 20개 확인 규칙에도 센다(REV1110A06).
            guard descendants.count < AssistantBatchPolicy.confirmThreshold else { return .rejected("has_children") }
            let removed = Set([goal.id] + descendants.map(\.id))
            let linked = snapshot.actuals.filter { $0.planID.map(removed.contains) == true || $0.routineID.map(removed.contains) == true }
            await deletePlans([goal.id])
            guard !snapshot.plans.contains(where: { $0.id == goal.id }) else { return .rejected("goal_failed") }
            return AssistantEditResult(before: AssistantDataText.goal(goal), after: language.text("지움", "Deleted"), actualIDs: Set(linked.map(\.id)))
        case let .addTripStop(title, day, coordinate, status, tripID):
            return await addAssistantTripStop(title: title, day: day, coordinate: coordinate, status: status, tripID: tripID)
        case let .updateTripStop(stopID, title, day, order, status):
            return await updateAssistantTripStop(stopID, title: title, day: day, order: order, status: status)
        case let .deleteTripStop(stopID):
            guard let stop = assistantStop(stopID) else { return .rejected("no_stop") }
            await removeTravelStop(stop.id)
            guard !snapshot.settings.travelPlanStops.contains(where: { $0.id == stop.id }) else { return .rejected("trip_failed") }
            return AssistantEditResult(before: AssistantDataText.stop(stop), after: language.text("지움", "Deleted"))
        case let .setTripItemStatus(tripID, itemID, status):
            return await setAssistantTripStatus(tripID: tripID, itemID: itemID, status: status)
        case let .updateSleep(recordID, start, end):
            return await correctAssistantSleep(recordID, start: start, end: end)
        case let .setLanguage(preference):
            let change = AssistantPreferenceChange(
                key: AssistantPreferenceChange.languageKey, before: preferences.value(AssistantPreferenceChange.languageKey), after: preference.rawValue
            )
            if change.before != change.after { preferences.set(change.key, value: change.after, model: self) }
            let old = change.before.flatMap(AppLanguagePreference.init(rawValue:))?.displayName ?? ""
            return AssistantEditResult(before: old, after: preference.displayName, preferences: change.before == change.after ? [] : [change])
        case let .setMapStyle(style):
            // 카카오 지도는 키가 든 빌드에서만 고를 수 있다(화면의 지도 고르기와 같다).
            if style == .kakao, !KakaoMapAvailability.isAvailable { return .rejected("not_available") }
            let before = snapshot.settings.mapDisplayStyle
            setMapDisplayStyle(style)
            return AssistantEditResult(
                before: AssistantDataText.mapStyle(before, language), after: AssistantDataText.mapStyle(snapshot.settings.mapDisplayStyle, language)
            )
        case let .setDisplayOption(option, enabled):
            let change = AssistantPreferenceChange(key: option.defaultsKey, before: preferences.value(option.defaultsKey), after: String(enabled))
            if change.before != change.after { preferences.set(change.key, value: change.after, model: self) }
            return AssistantEditResult(
                before: AssistantDataText.display(option, isOn: change.before != "false", language),
                after: AssistantDataText.display(option, isOn: enabled, language), preferences: change.before == change.after ? [] : [change]
            )
        case let .setBubble(start, end, text, kind):
            guard let added = AssistantBubbleStore.add(AssistantBubble(start: start, end: end, text: text, kind: kind), file: preferences.bubbleFile)
            else { return .rejected("bubble_limit") }
            var result = AssistantEditResult(after: "\(AssistantEditText.clock(start))–\(AssistantEditText.clock(end)) \(added.parsed?.display ?? text)")
            result.bubbleID = added.id
            return result
        case let .addExpense(entry):
            var value = entry
            await preferences.ledger.load()
            if let problem = AssistantExpenseChange.tripProblem(value, book: preferences.ledger) { return .rejected(problem) }
            value.amountKRW = preferences.ledger.krw(value.amount, currency: value.currency)
            let saved = await preferences.ledger.save(value)
            // 여행 기록이 바뀌면 끝난 여행의 정산 짝 기록도 다시 맞춘다(가계부 화면과 같다).
            if let tripID = saved.tripID { await preferences.ledger.syncTrip(tripID) }
            var result = AssistantEditResult(after: "\(value.title) \(LedgerMoney.text(value.amount, currency: value.currency, language: language))")
            result.ledgerEntryID = saved.id
            result.ledgerEntry = saved
            return result
        case let .addPaymentRule(rule):
            LedgerMessageRules.add(rule, defaults: preferences.defaults)
            // 시험 저장소로는 실제 받은 문자함·가계부를 건드리지 않는다.
            let added = preferences.isLive ? await PaymentInbox.reprocess(now: .now) : 0
            var result = AssistantEditResult(after: LedgerMessageRules.summary(rule, added: added, language: language))
            result.paymentRuleID = rule.id
            return result
        case let .classifyUnconfirmed(start, end, title, categoryID):
            guard isAssistantCategory(categoryID) else { return .rejected("unknown_category") }
            let limit = min(end, Date.now)
            guard limit.timeIntervalSince(start) >= 60 else { return .rejected("no_gap") }
            // 아직 아무 기록도 덮지 않은 부분만 채운다. 있는 기록은 건드리지 않는다.
            let gaps = ReviewCoverageEngine.unconfirmedRecords(actuals: snapshot.actuals, in: [TimeSpan(start: start, end: limit)])
                .map { $0.span(asOf: .now) }.filter { $0.duration >= 60 }
            guard !gaps.isEmpty else { return .rejected("no_gap") }
            let name = title ?? assistantCategoryTitle(categoryID, language: language)
            let option = ActivityCorrectionOption(
                id: "assistant.\(name)", title: name, behavior: nil, categoryID: categoryID,
                systemImage: "tag.fill", isAutomatic: false, isCustom: false
            )
            let known = Set(snapshot.actuals.map(\.id))
            for gap in gaps { await classifyUnconfirmedSpan(gap, with: option) }
            let added = snapshot.actuals.filter { !known.contains($0.id) }
            guard !added.isEmpty else { return .rejected("edit_failed") }
            return AssistantEditResult(
                before: "\(language.text("미확인", "Unconfirmed")) \(AssistantEditText.clock(start))–\(AssistantEditText.clock(limit))",
                after: name, actualIDs: Set(added.map(\.id))
            )
        case let .setTravelMode(moveID, mode, line):
            guard let segment = snapshot.travel.first(where: { $0.id == moveID }) else { return .rejected("no_record") }
            var result = AssistantEditResult(before: TravelMapMode(segment.mode).title(language))
            result.movementBefore = .init(snapshot, ids: [moveID])
            confirmTravel(moveID, mode: mode)
            guard snapshot.travel.first(where: { $0.id == moveID })?.mode == mode else { return .rejected("edit_failed") }
            result.after = TravelMapMode(mode).title(language)
            if let line, mode == .bus || mode == .subway {
                confirmRideLine(moveID, line: line)
                result.after += " · " + line
            }
            return result
        case let .updateExpense(entryID, change):
            await preferences.ledger.load()
            guard let before = preferences.ledger.entries.first(where: { $0.id == entryID }) else { return .rejected("no_record") }
            var result = AssistantEditResult(before: "\(before.title) \(LedgerMoney.text(before.amount, currency: before.currency, language: language))")
            result.ledgerBefore = before
            if change.delete {
                await preferences.ledger.delete(entryID)
                result.after = language.text("지움", "Deleted")
                return result
            }
            var value = change.applied(to: before)
            if change.touchesTrip, let problem = AssistantExpenseChange.tripProblem(value, book: preferences.ledger) { return .rejected(problem) }
            if value.amount != before.amount || value.currency != before.currency {
                value.amountKRW = preferences.ledger.krw(value.amount, currency: value.currency)
            }
            let saved = await preferences.ledger.save(value)
            for tripID in Set([before.tripID, saved.tripID].compactMap { $0 }) { await preferences.ledger.syncTrip(tripID) }
            result.after = "\(saved.title) \(LedgerMoney.text(saved.amount, currency: saved.currency, language: language))"
            result.ledgerEntryID = saved.id
            result.ledgerEntry = saved
            return result
        default:
            return await applyAssistantAppAction(action, preferences: preferences)
        }
    }

    private func assistantGoal(_ id: String) -> PlanRecord? {
        guard let uuid = UUID(uuidString: id), let plan = snapshot.plans.first(where: { $0.id == uuid }),
              GoalRecordPolicy.isGoal(plan), !plan.isFixed else { return nil }
        return plan
    }

    private func assistantStop(_ id: String) -> TravelPlanStop? {
        UUID(uuidString: id).flatMap { uuid in snapshot.settings.travelPlanStops.first { $0.id == uuid } }
    }

    /// 루틴 편집 화면과 같은 `updatePlan`으로 이름·기간을 고친다. 날짜는 하루 단위, 끝 날짜까지 포함한다.
    private func updateAssistantGoal(_ goalID: String, title: String?, start: Date?, end: Date?, categoryID: String?) -> AssistantEditResult {
        guard let goal = assistantGoal(goalID) else { return .rejected("no_goal") }
        if let categoryID, !isAssistantCategory(categoryID) { return .rejected("unknown_category") }
        let newCategory = categoryID ?? goal.categoryID
        let calendar = Calendar.autoupdatingCurrent
        let newStart = start ?? goal.span.start
        let newEnd = end.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? (start == nil ? goal.span.end : newStart.addingTimeInterval(goal.span.duration))
        guard newEnd > newStart else { return .rejected("invalid_time") }
        let span = TimeSpan(start: newStart, end: newEnd)
        let newTitle = title.map(GoalRecordPolicy.displayTitle) ?? goal.title
        let errorBefore = userFacingError
        updatePlan(
            goal.id, title: newTitle, categoryID: newCategory, middleCategoryName: goal.middleCategoryName,
            subCategoryName: goal.subCategoryName, span: span, parentID: goal.parentID, isImportant: goal.isImportant, repeatRules: goal.repeatRules
        )
        guard let updated = snapshot.plans.first(where: { $0.id == goal.id }), updated.title == newTitle, updated.span == span,
              updated.categoryID == newCategory else {
            userFacingError = errorBefore
            return .rejected("goal_failed")
        }
        return AssistantEditResult(before: AssistantDataText.goal(goal), after: AssistantDataText.goal(updated))
    }

    /// 좌표가 없으면 이름으로 찾고, `tripID`를 주면 그 여행에 붙인다(REV1110A06).
    private func addAssistantTripStop(
        title: String, day: Date, coordinate: AssistantCoordinate?, status: TripItemStatus?, tripID: String?
    ) async -> AssistantEditResult {
        let sameTrip = snapshot.settings.travelPlanStops.filter { tripID != nil && $0.tripID == tripID }
        if let tripID, sameTrip.isEmpty, snapshot.settings.travelTripItems?.contains(where: { $0.tripID == tripID }) != true {
            return .rejected("no_trip")
        }
        let near = (sameTrip.last ?? TravelPlanSchedule.stops(on: day, in: snapshot.settings.travelPlanStops).last)
            .map { AssistantCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        var place = coordinate
        if place == nil { place = await AssistantPlaceSearch.find(title, near) }
        guard let place else { return .rejected("place_not_found") }
        guard let stop = addTravelStop(title: title, latitude: place.latitude, longitude: place.longitude, day: day) else { return .rejected("trip_failed") }
        if let status, status != .planned { setTravelStopStatus(status, stopID: stop.id) }
        if let tripID, let index = snapshot.settings.travelPlanStops.firstIndex(where: { $0.id == stop.id }) {
            snapshot.settings.travelPlanStops[index].tripID = tripID
            await persist()
        }
        return AssistantEditResult(after: AssistantDataText.stop(snapshot.settings.travelPlanStops.first { $0.id == stop.id } ?? stop))
    }

    /// 여행 계획 화면의 순서·상태 편집과 같은 값을 고친다. 이어진 일정 이름·날짜도 함께 옮긴다.
    /// 저장하지 못하면 편집 전으로 돌리고, 바뀐 값을 확인한 뒤에만 반영했다고 알린다(REV1110A06).
    private func updateAssistantTripStop(_ stopID: String, title: String?, day: Date?, order: Int?, status: TripItemStatus?) async -> AssistantEditResult {
        guard acceptsDataMutation(), let stop = assistantStop(stopID) else { return .rejected("no_stop") }
        let calendar = Calendar.autoupdatingCurrent
        let previous = snapshot
        var stops = snapshot.settings.travelPlanStops
        var items = snapshot.settings.travelTripItems
        let shift = day.map { calendar.startOfDay(for: $0).timeIntervalSince(TravelPlanSchedule.localDay(stored: stop.day, calendar: calendar)) } ?? 0
        AssistantTripEdit.apply(
            to: &stops, items: &items, stopID: stop.id, title: title, day: day.map { calendar.startOfDay(for: $0) },
            order: order, status: status, shift: shift, calendar: calendar
        )
        if let planID = stop.planID, let plan = snapshot.plans.first(where: { $0.id == planID }), AssistantPlanLookup.isEditable(plan),
           title != nil || shift != 0 {
            let errorBefore = userFacingError
            updatePlan(
                plan.id, title: title ?? plan.title, categoryID: plan.categoryID, middleCategoryName: plan.middleCategoryName,
                subCategoryName: plan.subCategoryName, span: TimeSpan(start: plan.span.start.addingTimeInterval(shift), end: plan.span.end.addingTimeInterval(shift)),
                parentID: plan.parentID, isImportant: plan.isImportant, repeatRules: plan.repeatRules
            )
            userFacingError = errorBefore
        }
        snapshot.settings.travelPlanStops = stops
        snapshot.settings.travelTripItems = items
        guard await persistOrRollBack(userEditRollback(from: previous)),
              let updated = snapshot.settings.travelPlanStops.first(where: { $0.id == stop.id }),
              title.map({ updated.title == $0 }) ?? true, status.map({ TripItemStatus(raw: updated.status) == $0 }) ?? true,
              day.map({ TravelPlanSchedule.isSameDay(stored: updated.day, local: $0, calendar: calendar) }) ?? true
        else { return .rejected("trip_failed") }
        return AssistantEditResult(before: AssistantDataText.stop(stop), after: AssistantDataText.stop(updated))
    }

    private func setAssistantTripStatus(tripID: String, itemID: String, status: TripItemStatus) async -> AssistantEditResult {
        let items = snapshot.settings.travelTripItems ?? []
        guard let item = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return .rejected("no_trip_item") }
        let before = TripItemStatus(raw: item.status).title(.current)
        if let stop = snapshot.settings.travelPlanStops.first(where: { $0.tripID == tripID && $0.itemID == itemID }) {
            setTravelStopStatus(status, stopID: stop.id)
        }
        if snapshot.settings.travelTripItems?.contains(where: { $0.tripID == tripID && $0.itemID == itemID && TripItemStatus(raw: $0.status) != status }) == true {
            snapshot.settings.travelTripItems = items.map { value in
                var copy = value
                if value.tripID == tripID, value.itemID == itemID { copy.status = status.stored }
                return copy
            }
            await persist()
        }
        return AssistantEditResult(before: "\(item.title) \(before)", after: "\(item.title) \(status.title(.current))")
    }

    /// 수면 기록의 시작·끝을 교정표로 바꾼다(타임라인 시간 조정과 같은 `updateActualSpan`).
    private func correctAssistantSleep(_ recordID: String, start: AssistantScheduleTime?, end: AssistantScheduleTime?) async -> AssistantEditResult {
        guard let uuid = UUID(uuidString: recordID),
              let actual = snapshot.actuals.first(where: { $0.id == uuid && $0.categoryID == "sleep" }), let currentEnd = actual.endedAt
        else { return .rejected("no_sleep") }
        let calendar = Calendar.autoupdatingCurrent
        let newStart = start?.resolve(on: actual.startedAt, calendar: calendar)
        let newEnd = end?.resolve(on: currentEnd, calendar: calendar)
        guard start == nil || newStart != nil, end == nil || newEnd != nil,
              let span = AssistantMergePlan.retimed(start: actual.startedAt, end: currentEnd, newStart: newStart, newEnd: newEnd)
        else { return .rejected("invalid_time") }
        let known = Set(snapshot.actuals.map(\.id))
        await updateActualSpan(uuid, startAt: span.start, endAt: span.end)
        let correction = snapshot.settings.activityCorrections[uuid]
        guard correction?.startedAt == span.start, correction?.endedAt == span.end else { return .rejected("edit_failed") }
        // 확정 수면은 표시 기록을 새 id로 다시 만든다. 되돌릴 때 함께 치우도록 그 id도 담는다(REV1110A06).
        let fresh = snapshot.actuals.filter { $0.categoryID == "sleep" && !known.contains($0.id) }
        let after = snapshot.actuals.first { $0.id == uuid } ?? fresh.first { $0.startedAt == span.start }
        return AssistantEditResult(
            before: AssistantEditText.record(actual), after: after.map(AssistantEditText.record) ?? "",
            actualIDs: Set(fresh.map(\.id)).union([uuid])
        )
    }
}

/// 여행 핀 고치기 계산. 화면 없이 시험한다.
enum AssistantTripEdit {
    static func apply(
        to stops: inout [TravelPlanStop], items: inout [TravelTripItem]?, stopID: UUID,
        title: String?, day: Date?, order: Int?, status: TripItemStatus?, shift: TimeInterval, calendar: Calendar
    ) {
        guard let index = stops.firstIndex(where: { $0.id == stopID }) else { return }
        let original = stops[index]
        if let title { stops[index].title = title }
        if let status { stops[index].status = status.stored }
        if let day, !TravelPlanSchedule.isSameDay(stored: original.day, local: day, calendar: calendar) {
            stops[index].day = day
            stops[index].order = TravelPlanSchedule.stops(on: day, in: stops, calendar: calendar).filter { $0.id != stopID }.count
        }
        if let order {
            let target = TravelPlanSchedule.localDay(stored: stops[index].day, calendar: calendar)
            var dayStops = TravelPlanSchedule.stops(on: target, in: stops, calendar: calendar)
            if let from = dayStops.firstIndex(where: { $0.id == stopID }) {
                let moving = dayStops.remove(at: from)
                dayStops.insert(moving, at: min(order, dayStops.count))
                let positions = Dictionary(uniqueKeysWithValues: dayStops.enumerated().map { ($1.id, $0) })
                for position in stops.indices { if let value = positions[stops[position].id] { stops[position].order = value } }
            }
        }
        stops = TravelPlanSchedule.renumbered(stops)
        guard let tripID = original.tripID, let itemID = original.itemID, var list = items else { return }
        for position in list.indices where list[position].tripID == tripID && list[position].itemID == itemID {
            if let title { list[position].title = title }
            if let status { list[position].status = status.stored }
            if shift != 0 {
                list[position].start = list[position].start.addingTimeInterval(shift)
                list[position].end = list[position].end.addingTimeInterval(shift)
            }
        }
        items = list
    }
}

/// 「AI가 한 일」의 루틴·여행 글.
enum AssistantDataText {
    static func goal(_ plan: PlanRecord) -> String {
        let last = plan.span.end.addingTimeInterval(-1)
        return "\(day(plan.span.start))–\(day(last)) \(plan.title)"
    }

    static func stop(_ stop: TravelPlanStop) -> String { "\(day(TravelPlanSchedule.localDay(stored: stop.day))) #\(stop.order + 1) \(stop.title)" }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    /// 설정은 저장값이 아니라 화면에 보이는 이름으로 적는다(REV1110A06).
    static func mapStyle(_ style: MapDisplayStyle, _ language: MapHomeLanguage) -> String {
        switch style {
        case .standard: language.text("애플맵", "Apple Maps")
        case .hybrid: language.text("위성", "Satellite")
        case .mapLibreNight: language.text("야간", "Night")
        case .mapLibreContrast: language.text("실외(고대비)", "Outdoor (high contrast)")
        case .mapLibreCasual: language.text("계절", "Seasons")
        case .mapLibreRPG: language.text("판타지", "Fantasy")
        case .mapLibreInk: language.text("수묵", "Ink Wash")
        case .mapLibrePorcelain: language.text("백자", "Porcelain")
        case .kakao: language.text("카카오 지도", "Kakao Map")
        }
    }

    static func display(_ option: AssistantDisplayOption, isOn: Bool, _ language: MapHomeLanguage) -> String {
        let name = switch option {
        case .mapPhotos: language.text("지도에 사진", "Photos on map")
        case .mapRoutes: language.text("지도에 경로 선", "Route lines on map")
        case .mapFootprints: language.text("지도에 발자국", "Footprints on map")
        case .sidebar: language.text("시간 사이드바", "Time sidebar")
        case .vehicles: language.text("탈것 표시", "Show vehicles")
        }
        return "\(name) \(isOn ? language.text("켬", "On") : language.text("끔", "Off"))"
    }
}

/// 좌표 없는 여행 일정의 자리를 이름으로 찾는다. 시험은 바꿔 끼운다.
@MainActor
enum AssistantPlaceSearch {
    static var find: @MainActor (String, AssistantCoordinate?) async -> AssistantCoordinate? = live

    static func live(_ title: String, near: AssistantCoordinate?) async -> AssistantCoordinate? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = title
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 200_000, longitudinalMeters: 200_000
            )
        }
        guard let found = try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate else { return nil }
        return AssistantCoordinate(latitude: found.latitude, longitude: found.longitude)
    }
}

/// 장소·분류 명령의 한도(ACA1112A01). 서버와 같다.
enum AssistantCatalogLimits {
    static let placeName = 40
    static let categoryName = 20
    static let radius = 30.0...500.0
    static let places = 100

    static func radiusOK(_ value: Double?) -> Bool { value.map { $0.isFinite && radius.contains($0) } ?? true }

    static func isColor(_ text: String) -> Bool {
        text.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
    }
}

extension AppModel {
    /// 자주 가는 장소와 분류(ACA1112A01). 화면의 편집과 같은 함수를 쓰고, 화면 오류 알림은 띄우지 않는다.
    /// 되돌리기는 목록 전·후를 견준다(`AssistantEditDelta.places`·`categories`).
    func applyAssistantCatalogAction(_ action: AssistantCommand.Action) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        func sameName(_ name: String, except id: UUID? = nil) -> Bool {
            snapshot.settings.frequentPlaces.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        func describe(_ place: FrequentPlace) -> String { "\(place.displayName) · \(Int(place.radiusMeters.rounded()))m" }
        switch action {
        case let .addPlace(name, coordinate, radius, autoRecord):
            guard !sameName(name) else { return .rejected("duplicate") }
            guard snapshot.settings.frequentPlaces.count < AssistantCatalogLimits.places else { return .rejected("place_limit") }
            var place = FrequentPlace(kind: .custom, name: name)
            if let radius { place.radiusMeters = radius }
            if let autoRecord { place.isAutomaticRecordingEnabled = autoRecord }
            snapshot.settings.frequentPlaces.append(place)
            if let coordinate { setFrequentPlaceLocation(place.id, latitude: coordinate.latitude, longitude: coordinate.longitude) }
            await persist()
            // 가까운 등록 장소와 합쳐졌으면 그 장소로 남는다.
            let saved = snapshot.settings.frequentPlaces.first { $0.id == place.id } ?? place
            return AssistantEditResult(after: describe(saved))
        case let .updatePlace(placeID, name, coordinate, radius, autoRecord):
            guard let current = snapshot.settings.frequentPlaces.first(where: { $0.id == placeID }) else { return .rejected("no_place") }
            if let name, sameName(name, except: placeID) { return .rejected("duplicate") }
            // 바뀌는 값이 없으면 손대지 않는다(수정 시각만 바뀌어 되돌리기가 막히지 않게).
            let changesDetails = (name.map { $0 != current.name } ?? false) || (radius.map { $0 != current.radiusMeters } ?? false)
                || (autoRecord.map { $0 != current.isAutomaticRecordingEnabled } ?? false)
            let moves = coordinate.map { $0.latitude != current.point?.latitude || $0.longitude != current.point?.longitude } ?? false
            guard changesDetails || moves else { return .rejected("no_change") }
            if changesDetails {
                updateFrequentPlaceDetails(
                    placeID, name: name ?? current.name, radiusMeters: radius ?? current.radiusMeters,
                    minimumDwellMinutes: current.minimumDwellMinutes, isAutomaticRecordingEnabled: autoRecord ?? current.isAutomaticRecordingEnabled
                )
            }
            if moves, let coordinate { setFrequentPlaceLocation(placeID, latitude: coordinate.latitude, longitude: coordinate.longitude) }
            await persist()
            guard let saved = snapshot.settings.frequentPlaces.first(where: { $0.id == placeID }) else { return .rejected("edit_failed") }
            return AssistantEditResult(before: describe(current), after: describe(saved))
        case let .deletePlace(placeID):
            guard let current = snapshot.settings.frequentPlaces.first(where: { $0.id == placeID }) else { return .rejected("no_place") }
            let before = snapshot.settings.frequentPlaces
            deleteFrequentPlace(placeID)
            await persist()
            guard snapshot.settings.frequentPlaces != before else { return .rejected("no_change") }
            return AssistantEditResult(before: describe(current), after: language.text("지움", "Deleted"))
        case let .addCategory(name, color, icon):
            guard let category = try? CategoryCatalog.makeCustom(name: name, icon: icon ?? .activity, lightHex: color, existing: snapshot.categories)
            else { return .rejected("invalid_category") }
            snapshot.categories.append(category)
            snapshot.categories.sort { $0.sortOrder < $1.sortOrder }
            await persist()
            return AssistantEditResult(after: "\(category.name) \(category.lightHex)")
        case let .updateCategory(categoryID, name, color, icon, hidden):
            guard categoryID != "unconfirmed", let index = snapshot.categories.firstIndex(where: { $0.id == categoryID }) else { return .rejected("unknown_category") }
            let current = snapshot.categories[index]
            if let name, snapshot.categories.contains(where: { $0.id != categoryID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return .rejected("duplicate")
            }
            guard let updated = try? CategoryCatalog.update(current, name: name, icon: icon, lightHex: color, hidden: hidden) else { return .rejected("invalid_category") }
            guard updated != current else { return .rejected("no_change") }
            snapshot.categories[index] = updated
            await persist()
            func describe(_ value: CategoryDefinition) -> String {
                "\(value.name) \(value.lightHex)" + (value.isHidden ? " · " + language.text("숨김", "Hidden") : "")
            }
            return AssistantEditResult(before: describe(current), after: describe(updated))
        case .addTrip, .updateTrip, .deleteTrip:
            return await applyAssistantTripAction(action)
        case .resolvePlaceSuggestion, .setCarAudio, .setCalendarTitleDetail:
            return await applyAssistantPromptAction(action)
        default:
            return .rejected("invalid")
        }
    }
}

extension AppModel {
    /// `YYYY-MM-DD`에서 `days`일 뒤의 날짜 글.
    static func assistantDay(_ day: String, plus days: Int) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let parts = TravelTripDay.components(day), let first = utc.date(from: parts),
              let moved = utc.date(byAdding: .day, value: days, to: first) else { return nil }
        return TravelTripDay.string(for: moved, offsetSeconds: 0)
    }

    /// 여행 만들기·고치기·지우기(ACB1112A01). 화면과 같은 함수(`saveTravelTrip`·`shiftTravelTrip`·`deleteTravelTrip`)를 쓴다.
    func applyAssistantTripAction(_ action: AssistantCommand.Action) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        let trips = snapshot.settings.travelTrips ?? []
        func describe(_ trip: TravelTrip) -> String {
            if trip.isWish { return "\(trip.title) · " + language.text("\(trip.wishDays ?? 1)일(날짜 미정)", "\(trip.wishDays ?? 1) day(s), no dates") }
            return trip.startDay == trip.endDay ? "\(trip.title) · \(trip.startDay)" : "\(trip.title) · \(trip.startDay)–\(trip.endDay)"
        }
        switch action {
        case let .addTrip(draft):
            guard trips.count < AssistantCatalogLimits.places else { return .rejected("trip_limit") }
            var trip = draft
            // 나라를 주면 화면에서 만들 때처럼 깃발 자리와 여행지 통화를 잡는다.
            if let code = trip.countryCode, let country = TravelModeRegions.countries.first(where: { $0.code == code }) {
                trip.latitude = country.anchor.y
                trip.longitude = country.anchor.x
                if trip.currencyCode == nil, code != "KR" { trip.currencyCode = TravelModeRegions.currency(forCountry: code) }
            }
            guard await saveTravelTrip(trip) else { return .rejected("edit_failed") }
            return AssistantEditResult(after: describe(trip))
        case let .updateTrip(tripID, title, start, end):
            guard let old = trips.first(where: { $0.id == tripID }) else { return .rejected("no_trip") }
            var trip = old
            if let title { trip.title = title }
            if start != nil || end != nil {
                guard let first = start ?? (old.startDay.isEmpty ? nil : old.startDay) else { return .rejected("no_dates") }
                if end == nil, old.isWish {
                    // 날짜 없는 여행에 첫날을 정하면 정해 둔 날 수만큼 이어진다.
                    trip = TravelTripDirectory.scheduled(trip, startDay: first)
                } else if end == nil, let length = TravelTripDay.days(from: old.startDay, to: old.endDay), let last = Self.assistantDay(first, plus: length) {
                    // 첫날만 옮기면 길이를 지킨다.
                    trip.startDay = first
                    trip.endDay = last
                } else {
                    trip.startDay = first
                    trip.endDay = end ?? first
                    trip.wishDays = nil
                }
                guard (TravelTripDay.days(from: trip.startDay, to: trip.endDay) ?? -1) >= 0 else { return .rejected("end_before_start") }
            }
            guard trip != old else { return .rejected("no_change") }
            guard await saveTravelTrip(trip) else { return .rejected("edit_failed") }
            // 첫날을 옮겼으면 넣어 둔 일정 전체를 같은 날 수만큼 함께 옮긴다(화면과 같다).
            if !old.isWish, let moved = TravelTripDay.days(from: old.startDay, to: trip.startDay), moved != 0 {
                await shiftTravelTrip(trip.id, byDays: moved)
            }
            return AssistantEditResult(before: describe(old), after: describe(trip))
        case let .deleteTrip(tripID):
            guard let old = trips.first(where: { $0.id == tripID }) else { return .rejected("no_trip") }
            guard await deleteTravelTrip(tripID) else { return .rejected("edit_failed") }
            return AssistantEditResult(before: describe(old), after: language.text("지움", "Deleted"))
        default:
            return .rejected("invalid")
        }
    }
}

extension AssistantAppChange.CarAudio.Lists {
    init(_ settings: AppFeatureSettings) {
        self.init(registered: settings.registeredCarAudioNames, recent: settings.recentCarAudioNames, dismissed: settings.dismissedCarAudioNames)
    }
}

extension AppModel {
    /// 앱의 「확인할 것」을 AI가 끝낸다(HND1112A01). 화면에서 답할 때와 같은 함수를 쓴다.
    func applyAssistantPromptAction(_ action: AssistantCommand.Action) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        switch action {
        case let .resolvePlaceSuggestion(register, name, kind):
            // 앱이 지금 제안하고 있는 자리(앱 상태에 올린 것)에만 답한다. 여기서 새로 계산하지 않는다.
            guard let suggestion = frequentPlaceSuggestion else { return .rejected("no_suggestion") }
            let label = suggestion.suggestedName.flatMap { AssistantActivityBuilder.isAddressLike($0) ? nil : $0 } ?? language.text("제안한 곳", "Suggested place")
            guard register else {
                dismissFrequentPlaceSuggestion()
                await persist()
                return AssistantEditResult(before: label, after: language.text("다시 묻지 않음", "Won't ask again"))
            }
            if let name, snapshot.settings.frequentPlaces.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return .rejected("duplicate")
            }
            guard let placeID = registerFrequentPlaceSuggestion(as: kind ?? .custom) else { return .rejected("edit_failed") }
            if let name { renameFrequentPlace(placeID, name: name) }
            await persist()
            let saved = snapshot.settings.frequentPlaces.first { $0.id == placeID }
            return AssistantEditResult(before: label, after: saved?.displayName ?? name ?? label)
        case let .setCarAudio(name, isMyCar):
            let before = AssistantAppChange.CarAudio.Lists(settings)
            // 앱이 본 기기 이름만 받는다(최근 연결·등록·거절한 것).
            guard (before.registered + before.recent + before.dismissed).contains(name) else { return .rejected("no_device") }
            await setCarAudio(name, isMyCar: isMyCar)
            let after = AssistantAppChange.CarAudio.Lists(settings)
            guard after != before else { return .rejected("no_change") }
            var result = AssistantEditResult(before: name, after: isMyCar ? language.text("내 차로 등록", "Registered as my car") : language.text("내 차 아님", "Not my car"))
            result.appChange = AssistantAppChange(carAudio: .init(before: before, after: after))
            return result
        case let .setCalendarTitleDetail(title, detailID):
            let key = CalendarTitleClassification.key(title)
            let stored = snapshot.settings.calendarTitleDetails[key]
            guard stored == nil || stored?.detailID != detailID else { return .rejected("no_change") }
            await setCalendarTitleDetail(detailID, title: title, on: selectedDate)
            func name(_ id: String?) -> String {
                guard let id else { return language.text("분류 안 함", "Not classified") }
                let detail = CalendarTitleClassification.selectableCategories.flatMap(\.details).first { $0.id == id }
                return detail.map { RecordClassificationCatalog.localizedDetailTitle($0.title, language: language) } ?? id
            }
            var result = AssistantEditResult(
                before: "\(title): " + (stored == nil ? language.text("정하지 않음", "Not set") : name(stored?.detailID)), after: "\(title): \(name(detailID))"
            )
            result.appChange = AssistantAppChange(calendarTitle: .init(title: title, hadBefore: stored != nil, before: stored?.detailID, after: detailID))
            return result
        default:
            return .rejected("invalid")
        }
    }

    /// 내 차·일정 제목 분류가 명령 뒤에 또 바뀌지 않았는가.
    func assistantPromptChangeIsCurrent(_ change: AssistantAppChange?) -> Bool {
        if let car = change?.carAudio, AssistantAppChange.CarAudio.Lists(settings) != car.after { return false }
        if let title = change?.calendarTitle {
            let stored = snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key(title.title)]
            if stored == nil || stored?.detailID != title.after { return false }
        }
        return true
    }

    /// 내 차·일정 제목 분류를 명령 전으로 돌린다.
    func undoAssistantPromptChange(_ change: AssistantAppChange?) async {
        if let car = change?.carAudio {
            snapshot.settings.dismissedCarAudioNames = car.before.dismissed
            await updateCarAudioNames(registered: car.before.registered, recent: car.before.recent)
        }
        if let title = change?.calendarTitle {
            if title.hadBefore {
                await setCalendarTitleDetail(title.before, title: title.title, on: selectedDate)
            } else {
                await clearCalendarTitleDetail(title: title.title, on: selectedDate)
            }
        }
    }
}

// MARK: 등록부 동작 5묶음 — 분류·장소·설정 (ACT1114A09). 새 파일을 늘리지 않으려고 여기 둔다.
// 장소 종류 바꾸기는 화면에 그런 함수가 없어 넣지 않았다. 분류 색은 예전 `updateCategory`의 `color`다.

extension AssistantOperations {
    static let catalog: [any AssistantOperation.Type] = [
        MoveCategory.self, DeleteCategory.self, SetPlaceFloor.self, AddMyStop.self, UpdateMyStop.self, DeleteMyStop.self,
        SetDayCardItems.self, SetDayCardTime.self, SetAlert.self, SetCatOutfit.self,
    ]

    /// 알림 종류·하루 카드 시각의 키. 바꾸거나 되돌리면 하루 카드 예약을 다시 맞춘다.
    static let alarmKeys: Set<String> = [MapHomeAlarmSettings.storageKey, MapHomeAlarmSettings.dailyCardHourKey, MapHomeAlarmSettings.dailyCardMinuteKey]

    /// 하루 카드 알림 시각 `HH:mm`.
    @MainActor
    static func dayCardTime(_ defaults: UserDefaults) -> String {
        let time = MapHomeAlarmSettings.dailyCardTime(defaults)
        return String(format: "%02d:%02d", time.hour ?? 8, time.minute ?? 0)
    }

    @MainActor
    static func growthHistory(_ defaults: UserDefaults) -> MapHomeGrowthHistory? {
        defaults.data(forKey: MapHomeGrowthPolicy.storageKey).flatMap { try? JSONDecoder().decode(MapHomeGrowthHistory.self, from: $0) }
    }

    static func floorText(_ floor: Int?, _ language: MapHomeLanguage) -> String {
        floor.map { language.text("\($0)층", "Floor \($0)") } ?? language.text("층 없음", "No floor")
    }

    private static func onOff(_ isOn: Bool, _ language: MapHomeLanguage) -> String { isOn ? language.text("켬", "On") : language.text("끔", "Off") }

    /// 분류 차례 바꾸기(분류 목록을 끌어 옮기는 것과 같은 `moveCategories`). 자리는 「미확인」을 뺀 목록에서 센다(앱 상태의 차례와 같다).
    struct MoveCategory: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "moveCategory", fields: ["categoryId", "position"], counter: .settings,
            title: { $0.text("분류 차례 바꾸기", "Reorder categories") },
            guide: #""categoryId":"<categories[].id>","position":1} (moves one major category to that place in the list, 1 is the top; categories in GET /app are in their order)"#
        )

        let categoryID: String
        let position: Int

        init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let position = fields.integer("position", in: 1...100) else { return nil }
            self.categoryID = categoryID
            self.position = position
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model, language = host.language
            let sorted = model.snapshot.categories.sorted { $0.sortOrder < $1.sortOrder }
            let visible = sorted.filter { $0.id != "unconfirmed" }
            guard let from = visible.firstIndex(where: { $0.id == categoryID }), let index = sorted.firstIndex(where: { $0.id == categoryID }) else {
                return .rejected("unknown_category")
            }
            let to = min(position, visible.count) - 1
            guard to != from, let anchor = sorted.firstIndex(where: { $0.id == visible[to].id }) else { return .rejected("no_change") }
            model.moveCategories(fromOffsets: IndexSet(integer: index), toOffset: to > from ? anchor + 1 : anchor)
            await model.persist()
            func describe(_ place: Int) -> String { language.text("\(visible[from].name) · \(place)번째", "\(visible[from].name) · #\(place)") }
            return AssistantEditResult(before: describe(from + 1), after: describe(to + 1))
        }
    }

    /// 내가 만든 분류 지우기(분류 편집의 「삭제」와 같은 `deleteCustomCategory`). 그 분류의 일정·기록은 `moveTo`로 옮긴다.
    struct DeleteCategory: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "deleteCategory", fields: ["categoryId", "moveTo"], counter: .settings, deletes: true,
            title: { $0.text("내가 만든 분류 지우기", "Delete my categories") },
            guide: #""categoryId":"<categories[].id with custom true>","moveTo":"<another categories[].id>"} (deletes a category I made; its plans and records move to moveTo; built-in categories cannot be deleted, hide those with updateCategory; only when I asked)"#
        )

        let categoryID: String
        let moveTo: String

        init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let moveTo = fields.string("moveTo", max: 100), categoryID != moveTo else { return nil }
            self.categoryID = categoryID
            self.moveTo = moveTo
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model
            guard let target = model.snapshot.categories.first(where: { $0.id == categoryID }), moveTo != "unconfirmed",
                  let replacement = model.snapshot.categories.first(where: { $0.id == moveTo }) else { return .rejected("unknown_category") }
            guard !target.isBuiltIn else { return .rejected("not_editable") }
            let moved = Set(model.snapshot.actuals.filter { $0.categoryID == categoryID }.map(\.id))
            model.deleteCustomCategory(categoryID, reassigningTo: moveTo)
            await model.persist()
            guard !model.snapshot.categories.contains(where: { $0.id == categoryID }) else { return .rejected("edit_failed") }
            var result = AssistantEditResult(before: target.name, after: "\(host.deleted) → \(replacement.name)")
            result.actualIDs = moved
            return result
        }
    }

    /// 자주 가는 장소의 층(장소 편집의 층 고르기와 같은 `setFrequentPlaceFloor`). 높이 재기는 그 자리에서 사용자가 한다.
    struct SetPlaceFloor: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setPlaceFloor", fields: ["placeId", "floor"], counter: .settings,
            title: { $0.text("자주 가는 장소의 층 정하기", "Set floors of frequent places") },
            guide: #""placeId":"<places[].id>","floor":3} (which floor a registered place is on, -10 to 100, basements negative)"#
        )

        let placeID: UUID
        let floor: Int

        init?(fields: AssistantFields) {
            guard let placeID = fields.uuid("placeId"), let floor = fields.integer("floor", in: FloorCalibrationPrompt.range) else { return nil }
            self.placeID = placeID
            self.floor = floor
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model, language = host.language
            guard let place = model.snapshot.settings.frequentPlaces.first(where: { $0.id == placeID }) else { return .rejected("no_place") }
            guard place.floor != floor else { return .rejected("no_change") }
            model.setFrequentPlaceFloor(placeID, floor: floor)
            await model.persist()
            guard model.snapshot.settings.frequentPlaces.first(where: { $0.id == placeID })?.floor == floor else { return .rejected("edit_failed") }
            return AssistantEditResult(
                before: "\(place.displayName) · \(AssistantOperations.floorText(place.floor, language))",
                after: "\(place.displayName) · \(AssistantOperations.floorText(floor, language))"
            )
        }
    }

    private static func describe(_ stop: UserTransitLocation, _ language: MapHomeLanguage) -> String {
        "\(stop.name) · \(language.runtimeText(stop.kind.title, stop.kind.englishTitle)) · \(floorText(stop.floor, language))"
    }

    /// 내 정류장 더하기(「내 정류장」 화면과 같은 `addUserTransitLocation`). 좌표는 받기만 하고 내보내지 않는다.
    struct AddMyStop: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "addMyStop", fields: ["name", "kind", "latitude", "longitude", "floor"], counter: .settings, changes: 0,
            title: { $0.text("내 정류장 더하기", "Add my stations and stops") },
            guide: #""name":"Home stop","kind":"subwayStation|busStop|trainStation|airport|harbor","latitude":37.5,"longitude":127.0,"floor":-2} (registers a station or stop I use so rides from there are recognised; floor optional; my stops are in GET /app settings.myStops without coordinates)"#
        )

        let name: String
        let kind: UserTransitLocationKind
        let latitude: Double
        let longitude: Double
        let floor: Int?

        init?(fields: AssistantFields) {
            let floor = fields.integer("floor", in: FloorCalibrationPrompt.range)
            guard let name = fields.string("name", max: AssistantCatalogLimits.placeName), let kind: UserTransitLocationKind = fields.choice("kind"),
                  let latitude = fields.number("latitude"), abs(latitude) <= 90, let longitude = fields.number("longitude"), abs(longitude) <= 180,
                  fields.ok("floor", floor) else { return nil }
            self.name = name
            self.kind = kind
            self.latitude = latitude
            self.longitude = longitude
            self.floor = floor
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model
            let stops = model.snapshot.settings.userTransitLocations
            guard stops.count < AssistantCatalogLimits.places else { return .rejected("place_limit") }
            guard !stops.contains(where: { $0.kind == kind && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return .rejected("duplicate") }
            // 화면 오류 알림은 띄우지 않는다.
            let shown = model.userFacingError
            guard let id = model.addUserTransitLocation(name: name, kind: kind, latitude: latitude, longitude: longitude, floor: floor),
                  let saved = model.snapshot.settings.userTransitLocations.first(where: { $0.id == id }) else {
                model.userFacingError = shown
                return .rejected("edit_failed")
            }
            await model.persist()
            return AssistantEditResult(after: AssistantOperations.describe(saved, host.language))
        }
    }

    /// 내 정류장 이름·층 고치기(`renameUserTransitLocation`·`setUserTransitLocationFloor`).
    struct UpdateMyStop: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "updateMyStop", fields: ["stopId", "name", "floor", "clearFloor"], counter: .settings,
            title: { $0.text("내 정류장 고치기", "Edit my stations and stops") },
            guide: #""stopId":"<settings.myStops[].id>","name":"New name","floor":-1} (renames one of my stops or sets its floor; "clearFloor":true instead of floor for no floor; give at least one)"#
        )

        let stopID: UUID
        let name: String?
        let floor: Int?
        let clearsFloor: Bool

        init?(fields: AssistantFields) {
            let name = fields.string("name", max: AssistantCatalogLimits.placeName), floor = fields.integer("floor", in: FloorCalibrationPrompt.range)
            let clear = fields.flag("clearFloor")
            guard let stopID = fields.uuid("stopId"), fields.ok("name", name), fields.ok("floor", floor), fields.ok("clearFloor", clear), clear != false,
                  name != nil || floor != nil || clear == true, !(clear == true && floor != nil) else { return nil }
            self.stopID = stopID
            self.name = name
            self.floor = floor
            clearsFloor = clear == true
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model
            guard let old = model.snapshot.settings.userTransitLocations.first(where: { $0.id == stopID }) else { return .rejected("no_stop") }
            if let name { model.renameUserTransitLocation(stopID, name: name) }
            if floor != nil || clearsFloor { model.setUserTransitLocationFloor(stopID, floor: floor) }
            guard let saved = model.snapshot.settings.userTransitLocations.first(where: { $0.id == stopID }), saved != old else { return .rejected("no_change") }
            await model.persist()
            return AssistantEditResult(before: AssistantOperations.describe(old, host.language), after: AssistantOperations.describe(saved, host.language))
        }
    }

    /// 내 정류장 지우기(`deleteUserTransitLocation`).
    struct DeleteMyStop: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "deleteMyStop", fields: ["stopId"], counter: .settings, deletes: true,
            title: { $0.text("내 정류장 지우기", "Delete my stations and stops") },
            guide: #""stopId":"<settings.myStops[].id>"} (deletes one of my stations or stops; only when I asked)"#
        )

        let stopID: UUID

        init?(fields: AssistantFields) {
            guard let stopID = fields.uuid("stopId") else { return nil }
            self.stopID = stopID
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model
            guard let old = model.snapshot.settings.userTransitLocations.first(where: { $0.id == stopID }) else { return .rejected("no_stop") }
            model.deleteUserTransitLocation(stopID)
            await model.persist()
            return AssistantEditResult(before: AssistantOperations.describe(old, host.language), after: host.deleted)
        }
    }

    /// 하루 카드에 올릴 항목(카드의 「항목 고르기」와 같은 저장 값, 4개까지).
    struct SetDayCardItems: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setDayCardItems", fields: ["items"], counter: .settings,
            title: { $0.text("하루 카드 항목 고르기", "Choose day card figures") },
            guide: #""items":["sleep","steps","expense"]} (up to four figures on my daily share card, in order; [] for none; any of \#(MapHomeCardMetricOption.all.map(\.id).joined(separator: "|")); current ones in GET /app settings.dayCard.items)"#
        )

        let items: [String]

        init?(fields: AssistantFields) {
            let known = Set(MapHomeCardMetricOption.all.map(\.id))
            guard let items = fields.texts("items", max: 40, count: 0...MapHomeCardMetricSelection.maximum), items.allSatisfy(known.contains) else { return nil }
            self.items = items
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            let before = MapHomeCardMetricSelection.load(host.defaults)
            guard before != items, let change = host.changing(MapHomeCardMetricSelection.storageKey, { MapHomeCardMetricSelection.save(items, defaults: host.defaults) }) else {
                return .rejected("no_change")
            }
            func describe(_ ids: [String]) -> String { ids.compactMap { MapHomeCardMetricOption(id: $0)?.title(language) }.joined(separator: ", ") }
            var result = AssistantEditResult(before: describe(before), after: describe(items))
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 하루 카드 알림 시각(알림 설정의 시각 고르기와 같은 두 키). 예약도 화면처럼 다시 맞춘다.
    struct SetDayCardTime: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setDayCardTime", fields: ["time"], counter: .settings,
            title: { $0.text("하루 카드 알림 시각 바꾸기", "Change the day card time") },
            guide: #""time":"08:00"} (when the daily "yesterday's card is ready" alert arrives; current time in GET /app settings.dayCard.time)"#
        )

        let minutes: Int

        init?(fields: AssistantFields) {
            guard let minutes = fields.minutes("time") else { return nil }
            self.minutes = minutes
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let defaults = host.defaults
            let before = AssistantOperations.dayCardTime(defaults)
            let after = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            guard before != after else { return .rejected("no_change") }
            let changes = [
                host.changing(MapHomeAlarmSettings.dailyCardHourKey) { defaults.set(minutes / 60, forKey: MapHomeAlarmSettings.dailyCardHourKey) },
                host.changing(MapHomeAlarmSettings.dailyCardMinuteKey) { defaults.set(minutes % 60, forKey: MapHomeAlarmSettings.dailyCardMinuteKey) },
            ].compactMap { $0 }
            if host.preferences.isLive { await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: host.language) }
            var result = AssistantEditResult(before: before, after: after)
            result.appChange = AssistantAppChange(stored: changes)
            return result
        }
    }

    /// 알림 종류 하나 켜고 끄기(알림 설정의 스위치와 같은 저장 값). iOS 알림 권한은 건드리지 않는다.
    struct SetAlert: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setAlert", fields: ["alert", "enabled"], counter: .settings,
            title: { $0.text("알림 종류 켜고 끄기", "Switch alert kinds on or off") },
            guide: #""alert":"\#(MapHomeAlarmKind.allCases.map(\.rawValue).joined(separator: "|"))","enabled":false} (one kind of app alert; those on are in GET /app settings.alertsOn; this does not grant the iOS notification permission)"#
        )

        let kind: MapHomeAlarmKind
        let enabled: Bool

        init?(fields: AssistantFields) {
            guard let kind: MapHomeAlarmKind = fields.choice("alert"), let enabled = fields.flag("enabled") else { return nil }
            self.kind = kind
            self.enabled = enabled
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            var settings = MapHomeAlarmSettings.stored(host.defaults)
            guard settings.enabled.contains(kind) != enabled else { return .rejected("no_change") }
            if enabled { settings.enabled.insert(kind) } else { settings.enabled.remove(kind) }
            guard let change = host.changing(MapHomeAlarmSettings.storageKey, { host.defaults.set(settings.rawValue, forKey: MapHomeAlarmSettings.storageKey) }) else {
                return .rejected("no_change")
            }
            if host.preferences.isLive { await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language) }
            let name = kind.title(language)
            var result = AssistantEditResult(before: "\(name): \(AssistantOperations.onOff(!enabled, language))", after: "\(name): \(AssistantOperations.onOff(enabled, language))")
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 화랑이 꾸미기: 이미 받은 장식 하나를 입힌다(집 성장 화면의 「착용」과 같은 `equipAccessory`).
    struct SetCatOutfit: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setCatOutfit", fields: ["accessoryId"], counter: .settings,
            title: { $0.text("고양이 장식 입히기", "Dress my cat") },
            guide: #""accessoryId":"<settings.outfit.owned[]>"} (puts on one accessory I already earned; one hat, one scarf and one tail ribbon can be worn together; worn ones are in GET /app settings.outfit.worn)"#
        )

        let accessoryID: String

        init?(fields: AssistantFields) {
            guard let accessoryID = fields.string("accessoryId", max: 100), accessoryID.hasPrefix("cat.accessory.") else { return nil }
            self.accessoryID = accessoryID
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            guard var history = AssistantOperations.growthHistory(host.defaults), history.season.accessories.contains(accessoryID) else { return .rejected("no_accessory") }
            guard !history.season.isEquipped(accessoryID) else { return .rejected("no_change") }
            func name(_ id: String?) -> String {
                guard let id else { return "" }
                return MapHomeGrowthAccessoryCatalog.landmark(for: id).map { language.runtimeText($0.name, $0.englishName) } ?? id
            }
            let before = name(history.season.equipped(MapHomeGrowthAccessoryCatalog.kind(for: accessoryID)))
            guard MapHomeGrowthPolicy.equipAccessory(accessoryID, in: &history.season), let encoded = try? JSONEncoder().encode(history),
                  let change = host.changing(MapHomeGrowthPolicy.storageKey, { host.defaults.set(encoded, forKey: MapHomeGrowthPolicy.storageKey) }) else {
                return .rejected("edit_failed")
            }
            var result = AssistantEditResult(before: before, after: name(accessoryID))
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }
}
