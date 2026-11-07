import Foundation
import TaptionPlanCore

extension AppModel {
    @discardableResult
    func addPlan(
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        startAt: Date,
        duration: TimeInterval,
        parentID: UUID? = nil,
        repeatRules: [GoalRepeatRule]? = nil
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, duration > 0 else { return nil }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)
        var plan: PlanRecord
        if let parentID,
           let parent = snapshot.plans.first(where: { $0.id == parentID }) {
            let childDuration = min(duration, parent.span.duration)
            let latestStart = parent.span.end.addingTimeInterval(-childDuration)
            let adjustedStart = min(
                max(startAt, parent.span.start),
                latestStart
            )
            do {
                plan = try GoalDecompositionEngine.makeChild(
                    parent: parent,
                    title: cleanTitle,
                    span: TimeSpan(
                        start: adjustedStart,
                        end: adjustedStart.addingTimeInterval(childDuration)
                    ),
                    categoryID: categoryID
                )
                plan.repeatRules = cleanedRepeatRules
                plan.middleCategoryName = Self.cleanHierarchyName(
                    middleCategoryName
                )
                plan.subCategoryName = Self.cleanHierarchyName(
                    subCategoryName
                )
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "상위 루틴 안에 계획을 배치하지 못했습니다.",
                    english: "Could not place the plan inside the parent routine."
                )
                return nil
            }
        } else {
            plan = PlanRecord(
                title: cleanTitle,
                span: TimeSpan(
                    start: startAt,
                    end: startAt.addingTimeInterval(duration)
                ),
                categoryID: categoryID,
                middleCategoryName: Self.cleanHierarchyName(
                    middleCategoryName
                ),
                subCategoryName: Self.cleanHierarchyName(subCategoryName),
                repeatRules: cleanedRepeatRules
            )
        }
        let previous = snapshot
        snapshot.plans.append(plan)
        if plan.parentID == nil,
           let rules = plan.repeatRules {
            snapshot.plans.append(
                contentsOf: repeatActionItems(for: plan, rules: rules)
            )
        }
        snapshot.plans.sort { $0.span.start < $1.span.start }
        scheduleUserEditSave(from: previous)
        return plan.id
    }

    private static func cleanHierarchyName(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    func updatePlan(
        _ planID: UUID,
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        span: TimeSpan,
        parentID: UUID?,
        isImportant: Bool,
        repeatRules: [GoalRepeatRule]? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "수정할 계획을 찾지 못했습니다.",
                english: "Could not find the plan to edit."
            )
            return
        }
        guard !snapshot.plans[index].isFixed else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더 고정 일정은 캘린더에서 수정해 주세요.",
                english: "Edit fixed calendar events in the Calendar app."
            )
            return
        }
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanTitle.isEmpty, span.duration > 0 else {
            userFacingError = AppLanguagePreference.text(
                korean: "계획 이름과 시간을 확인해 주세요.",
                english: "Check the plan name and time."
            )
            return
        }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)

        var updated = snapshot.plans[index]
        updated.title = cleanTitle
        updated.categoryID = categoryID
        updated.middleCategoryName = Self.cleanHierarchyName(
            middleCategoryName
        )
        updated.subCategoryName = Self.cleanHierarchyName(subCategoryName)
        updated.span = span
        updated.parentID = parentID
        updated.isImportant = isImportant
        updated.repeatRules = cleanedRepeatRules
        updated.updatedAt = .now

        var candidate = snapshot.plans
        candidate[index] = updated
        candidate.removeAll {
            $0.parentID == planID && $0.origin == .repeatRule
        }
        do {
            try PlanHierarchy.validate(candidate)
            if let parentID,
               let parent = candidate.first(where: {
                   $0.id == parentID
               }),
               (span.start < parent.span.start
                   || span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(
                of: planID,
                in: candidate
            )
            guard children.allSatisfy({
                span.start <= $0.span.start && $0.span.end <= span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            if parentID == nil,
               Self.isGoalTitle(cleanTitle),
               let rules = cleanedRepeatRules {
                candidate.append(
                    contentsOf: repeatActionItems(for: updated, rules: rules)
                )
                try PlanHierarchy.validate(candidate)
            }
            let previous = snapshot
            snapshot.plans = candidate.sorted {
                $0.span.start < $1.span.start
            }
            scheduleUserEditSave(from: previous)
        } catch PlanningError.parentCycle {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 자기 하위 루틴 안으로 옮길 수 없습니다.",
                english: "A plan cannot be moved inside its own sub-routine."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "상위·하위 계획의 기간 안에서 시간을 정해 주세요.",
                english: "Choose a time within the period of the parent and child plans."
            )
        }
    }

    /// Attach an existing action item to a routine without creating a
    /// duplicate plan. Re-selecting a routine moves an already grouped action
    /// after validating the new parent, so the detail tab can expose a single
    /// "루틴 연결/변경" action.
    func connectActionItem(
        _ planID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let planIndex = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }), let target = snapshot.plans.first(where: { $0.id == goalID }),
              GoalRecordPolicy.isGoal(target) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 루틴 또는 액션아이템을 찾지 못했습니다.",
                english: "Could not find the routine or action item to link."
            )
            return
        }
        let plan = snapshot.plans[planIndex]
        guard plan.origin != .repeatRule,
              !GoalRecordPolicy.isGoal(plan),
              !AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                  plan.categoryID
              ) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 루틴은 액션아이템으로 연결할 수 없습니다.",
                english: "Repeating segments and routines cannot be linked as action items."
            )
            return
        }
        do {
            var candidatePlans = snapshot.plans
            if let planIndex = candidatePlans.firstIndex(where: { $0.id == planID }) {
                // Clear the old parent first. PlanHierarchy.attach then
                // validates the same action against the new routine's span.
                candidatePlans[planIndex].parentID = nil
            }
            let attached = try PlanHierarchy.attach(
                child: candidatePlans[planIndex],
                to: goalID,
                in: candidatePlans
            )
            candidatePlans[planIndex] = attached
            try PlanHierarchy.validate(candidatePlans)
            snapshot.plans = candidatePlans
            snapshot.plans.sort { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            await persist()
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "액션아이템의 시간이 루틴 기간 안에 있어야 합니다.",
                english: "The action item's time must fall within the routine's period."
            )
        } catch PlanningError.parentCycle {
            userFacingError = AppLanguagePreference.text(
                korean: "루틴의 하위 항목을 다시 연결할 수 없습니다.",
                english: "A routine's sub-items cannot be relinked."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "액션아이템을 루틴에 연결하지 못했습니다.",
                english: "Could not link the action item to the routine."
            )
        }
    }

    /// Attach an existing activity/actual record to a goal. This is a
    /// lightweight evidence link; it deliberately does not move the record
    /// or create a hierarchy child plan.
    func connectActualRecord(
        _ actualID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let actualIndex = snapshot.actuals.firstIndex(where: {
            $0.id == actualID
        }), let goal = snapshot.plans.first(where: {
            $0.id == goalID && !$0.isFixed && $0.status != .skipped
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 실제 기록 또는 루틴을 찾지 못했습니다.",
                english: "Could not find the actual record or routine to link."
            )
            return
        }

        let actual = snapshot.actuals[actualIndex]
        guard actual.span().intersection(with: goal.span) != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "실제 기록 시간이 루틴 기간 안에 있어야 합니다.",
                english: "The actual record's time must fall within the routine's period."
            )
            return
        }

        guard GoalRecordPolicy.isGoal(goal)
                || (goal.origin != .repeatRule && goal.origin != .calendar) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다.",
                english: "Repeating segments and events cannot be used as link targets."
            )
            return
        }

        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
                || GoalRecordPolicy.isGoal(goal) else {
            userFacingError = AppLanguagePreference.text(
                korean: "수면·활동 기록은 루틴에만 연결할 수 있습니다.",
                english: "Sleep and activity records can only be linked to routines."
            )
            return
        }

        var updated = actual
        if GoalRecordPolicy.isGoal(goal) {
            updated.routineID = goal.id
            updated.planID = nil
        } else {
            updated.planID = goal.id
            updated.routineID = routineAncestorID(
                for: goal.id
            )
        }
        guard let edit = PlanActualEdit(replacing: updated, at: actualIndex, in: snapshot.actuals) else { return }
        let normalizationWasPending = needsLocalRecordNormalization
        snapshot.actuals = edit.result
        // Linking does not alter classification or require another historical normalization.
        needsLocalRecordNormalization = normalizationWasPending
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
        }
        await persist(actualEdit: edit)
    }

    /// Create a relationship only after the user explicitly taps the source
    /// record and chooses a routine/action. Activity records use their typed
    /// fields so routine progress can count them; location/travel/calendar
    /// records are retained as generic graph links.
    func connectRecordNode(
        _ sourceNodeID: String,
        to planID: UUID
    ) async {
        guard let target = snapshot.plans.first(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "연결할 루틴 또는 액션아이템을 찾지 못했습니다.",
                english: "Could not find the routine or action item to link."
            )
            return
        }
        guard GoalRecordPolicy.isGoal(target)
                || (target.origin != .repeatRule && target.origin != .calendar) else {
            userFacingError = AppLanguagePreference.text(
                korean: "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다.",
                english: "Repeating segments and events cannot be used as link targets."
            )
            return
        }
        let targetNodeID = "\(GoalRecordPolicy.isGoal(target) ? "routine" : "action").\(planID.uuidString)"
        guard sourceNodeID != targetNodeID else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 항목에는 연결할 수 없습니다.",
                english: "An item cannot be linked to itself."
            )
            return
        }

        if sourceNodeID.hasPrefix("automatic.actual."),
           let actualID = UUID(
               uuidString: String(sourceNodeID.dropFirst("automatic.actual.".count))
           ), let actualIndex = snapshot.actuals.firstIndex(where: {
               $0.id == actualID
           }) {
            guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(
                snapshot.actuals[actualIndex]
            ) || GoalRecordPolicy.isGoal(target) else {
                userFacingError = AppLanguagePreference.text(
                    korean: "수면·활동 기록은 루틴에만 연결할 수 있습니다.",
                    english: "Sleep and activity records can only be linked to routines."
                )
                return
            }
            if GoalRecordPolicy.isGoal(target) {
                snapshot.actuals[actualIndex].routineID = planID
                snapshot.actuals[actualIndex].planID = nil
            } else {
                snapshot.actuals[actualIndex].planID = planID
                snapshot.actuals[actualIndex].routineID = routineAncestorID(
                    for: planID
                )
            }
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
        } else {
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
            snapshot.recordLinks.append(
                RecordLink(fromNodeID: sourceNodeID, toNodeID: targetNodeID)
            )
        }
        await persist()
    }

    /// Save the portion of a routine that was actually performed.  The
    /// interval is deliberately kept as a separate ActualRecord so the
    /// planned block remains intact and the dashboard can distinguish a full
    /// completion from a partial run.
    func updateRoutineActualInterval(
        planID: UUID,
        actualID: UUID? = nil,
        startedAt: Date,
        endedAt: Date?
    ) async {
        guard acceptsDataMutation() else { return }
        guard let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "루틴을 찾지 못했습니다.",
                english: "Could not find the routine."
            )
            return
        }
        let minimumEnd = startedAt.addingTimeInterval(60)
        let normalizedEnd = endedAt.map { max(minimumEnd, $0) }
        let existingIndex = actualID.flatMap { id in
            snapshot.actuals.firstIndex(where: { $0.id == id })
        } ?? snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.source == .manual
        })
        let routineID = routineAncestorID(for: planID)

        if let actualIndex = existingIndex {
            snapshot.actuals[actualIndex].planID = planID
            snapshot.actuals[actualIndex].routineID = routineID
            snapshot.actuals[actualIndex].startedAt = startedAt
            snapshot.actuals[actualIndex].endedAt = normalizedEnd
            snapshot.actuals[actualIndex].title = snapshot.plans[planIndex].title
            snapshot.actuals[actualIndex].categoryID = snapshot.plans[planIndex].categoryID
        } else {
            snapshot.actuals.append(
                ActualRecord(
                    planID: planID,
                    routineID: routineID,
                    title: snapshot.plans[planIndex].title,
                    categoryID: snapshot.plans[planIndex].categoryID,
                    startedAt: startedAt,
                    endedAt: normalizedEnd,
                    source: .manual,
                    confidence: .high
                )
            )
        }

        let performed = normalizedEnd.map {
            max(0, $0.timeIntervalSince(startedAt))
        } ?? 0
        let planned = snapshot.plans[planIndex].span.duration
        if planned > 0, performed >= planned * 0.999 {
            snapshot.plans[planIndex].status = .completed
        } else if snapshot.plans[planIndex].status == .completed {
            snapshot.plans[planIndex].status = .planned
        }
        snapshot.plans[planIndex].updatedAt = .now
        await persist()
    }

    private func routineAncestorID(for planID: UUID) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = snapshot.plans.first(where: { $0.id == id }) {
            if GoalRecordPolicy.isGoal(plan) { return plan.id }
            currentID = plan.parentID
        }
        return nil
    }

    private static func cleanGoalRepeatRules(
        _ rules: [GoalRepeatRule]?
    ) -> [GoalRepeatRule]? {
        let cleaned = (rules ?? []).compactMap { rule -> GoalRepeatRule? in
            let weekdays = Set(rule.weekdays.filter { (1...7).contains($0) })
            guard !weekdays.isEmpty else { return nil }
            var value = rule
            value.name = Self.cleanHierarchyName(rule.name)
            value.weekdays = weekdays
            value.startMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.startMinuteOfDay)
            )
            value.endMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.endMinuteOfDay)
            )
            return value
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isGoalTitle(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.hasPrefix(GoalRecordPolicy.currentPrefix)
            || clean.hasPrefix(GoalRecordPolicy.legacyPrefix)
    }

    private func repeatActionItems(
        for goal: PlanRecord,
        rules: [GoalRepeatRule],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PlanRecord] {
        guard !rules.isEmpty, goal.span.duration >= 60 else { return [] }

        let goalName = cleanGoalDisplayName(goal.title)
        let middleName = Self.cleanHierarchyName(goal.middleCategoryName)
            ?? goalName
        var cursor = calendar.startOfDay(for: goal.span.start)
        let lastDay = calendar.startOfDay(for: goal.span.end)
        var values: [PlanRecord] = []
        var safetyCounter = 0

        while cursor <= lastDay, safetyCounter < 5_000 {
            safetyCounter += 1
            let weekday = calendar.component(.weekday, from: cursor)
            for rule in rules where rule.weekdays.contains(weekday) {
                guard let rawStart = calendar.date(
                    byAdding: .minute,
                    value: rule.startMinuteOfDay,
                    to: cursor
                ) else {
                    continue
                }
                let endBase: Date
                if rule.endMinuteOfDay <= rule.startMinuteOfDay {
                    endBase = calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: cursor
                    ) ?? cursor.addingTimeInterval(86_400)
                } else {
                    endBase = cursor
                }
                guard let rawEnd = calendar.date(
                    byAdding: .minute,
                    value: rule.endMinuteOfDay,
                    to: endBase
                ) else {
                    continue
                }

                let start = max(rawStart, goal.span.start)
                let end = min(rawEnd, goal.span.end)
                guard end.timeIntervalSince(start) >= 60 else {
                    continue
                }

                values.append(
                    PlanRecord(
                        title: repeatActionTitle(
                            goalName: goalName,
                            rule: rule
                        ),
                        span: TimeSpan(start: start, end: end),
                        categoryID: goal.categoryID,
                        middleCategoryName: middleName,
                        subCategoryName: repeatRuleDisplayName(rule),
                        parentID: goal.id,
                        origin: .repeatRule
                    )
                )
            }

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: cursor
            ) else {
                break
            }
            cursor = nextDay
        }

        return values.sorted { $0.span.start < $1.span.start }
    }

    private func cleanGoalDisplayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmed.hasPrefix(GoalRecordPolicy.currentPrefix) {
            prefix = GoalRecordPolicy.currentPrefix
        } else if trimmed.hasPrefix(GoalRecordPolicy.legacyPrefix) {
            prefix = GoalRecordPolicy.legacyPrefix
        } else {
            return trimmed
        }
        let clean = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? trimmed : String(clean)
    }

    private func repeatActionTitle(
        goalName: String,
        rule: GoalRepeatRule
    ) -> String {
        guard let ruleName = repeatRuleDisplayName(rule),
              !ruleName.isEmpty,
              ruleName != goalName else {
            return goalName
        }
        return "\(goalName) · \(ruleName)"
    }

    private func repeatRuleDisplayName(_ rule: GoalRepeatRule) -> String? {
        let clean = Self.cleanHierarchyName(rule.name)
        return clean ?? Self.repeatWeekdayText(rule.weekdays)
    }

    private static func repeatWeekdayText(_ weekdays: Set<Int>) -> String {
        let normalized = Set(weekdays.filter { (1...7).contains($0) })
        if normalized == [1, 2, 3, 4, 5, 6, 7] {
            return AppLanguagePreference.text(korean: "매일", english: "Daily")
        }
        if normalized == [2, 3, 4, 5, 6] {
            return AppLanguagePreference.text(korean: "주중", english: "Weekdays")
        }
        if normalized == [1, 7] {
            return AppLanguagePreference.text(korean: "주말", english: "Weekends")
        }
        // Index 0 is Sunday to match `Calendar` weekday numbers (1...7).
        let labels = AppLanguagePreference.text(
            korean: "일,월,화,수,목,금,토",
            english: "Sun,Mon,Tue,Wed,Thu,Fri,Sat"
        ).split(separator: ",").map(String.init)
        return [2, 3, 4, 5, 6, 7, 1]
            .filter { normalized.contains($0) }
            .map { labels[$0 - 1] }
            .joined(separator: AppLanguagePreference.text(korean: "·", english: ", "))
    }

    func deletePlan(_ planID: UUID) async {
        guard let plan = snapshot.plans.first(where: {
            $0.id == planID
        }) else {
            return
        }
        clearUserEditRedoHistory()
        let previous = snapshot
        let descendants = (try? PlanHierarchy.descendants(
            of: planID,
            in: snapshot.plans
        )) ?? []
        let deletedIDs = Set([planID] + descendants.map(\.id))
        invalidateReviewArchives(
            spans: ([plan] + descendants).map(\.span),
            dates: snapshot.memos.compactMap { memo in
                memo.planID.map(deletedIDs.contains) == true
                    ? memo.occurredAt
                    : nil
            }
        )
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            deletedIDs.map(CloudBackupRecordKey.plan)
        )
        snapshot.plans.removeAll { deletedIDs.contains($0.id) }
        snapshot.memos = snapshot.memos.map { memo in
            var detached = memo
            if let planID = memo.planID, deletedIDs.contains(planID) {
                detached.planID = nil
            }
            if let targetID = memo.targetID,
               targetID.hasPrefix("plan."),
               let targetPlanID = UUID(
                   uuidString: String(targetID.dropFirst("plan.".count))
               ),
               deletedIDs.contains(targetPlanID) {
                detached.targetID = nil
            }
            return detached
        }
        snapshot.actuals = snapshot.actuals.map { actual in
            guard actual.planID.map(deletedIDs.contains) == true
                || actual.routineID.map(deletedIDs.contains) == true else {
                return actual
            }
            var preserved = actual
            if preserved.planID.map(deletedIDs.contains) == true {
                preserved.planID = nil
            }
            if preserved.routineID.map(deletedIDs.contains) == true {
                preserved.routineID = nil
            }
            return preserved
        }
        removeRecordLinks { link in
            recordNodePlanID(link.fromNodeID).map(deletedIDs.contains) == true
                || recordNodePlanID(link.toNodeID).map(deletedIDs.contains) == true
        }
        selectedGroupPlanID = nil
        groupNavigationPath.removeAll {
            deletedIDs.contains($0)
        }
        let majorCategory = currentMajorCategory(for: plan)
        try? await liveActivityController.stop(
            plan: plan,
            catStyle: snapshot.settings.catStyle,
            majorCategoryID: majorCategory.id,
            majorCategoryTitle: majorCategory.title,
            majorCategorySystemImage: majorCategory.systemImage
        )
        await persistOrRollBack(userEditRollback(from: previous))
    }

    private func recordNodePlanID(_ nodeID: String) -> UUID? {
        for prefix in ["routine.", "action."] where nodeID.hasPrefix(prefix) {
            return UUID(uuidString: String(nodeID.dropFirst(prefix.count)))
        }
        return nil
    }

    func removeRecordLinks(
        where shouldRemove: (RecordLink) -> Bool
    ) {
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            snapshot.recordLinks.lazy
                .filter(shouldRemove)
                .map { CloudBackupRecordKey.link($0.id) }
        )
        snapshot.recordLinks.removeAll(where: shouldRemove)
    }

    func addPlanToCalendar(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더로 보낼 계획을 찾지 못했습니다.",
                english: "Could not find the plan to send to Calendar."
            )
            return
        }
        if snapshot.plans[index].externalEventID != nil {
            return
        }
        if !permissionState(for: .calendar).isGranted {
            await requestCalendar()
        }
        guard permissionState(for: .calendar).isGranted else {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더 권한을 허용해 주세요.",
                english: "Please allow Calendar access."
            )
            return
        }
        do {
            let calendarID = snapshot.settings.selectedCalendarIDs.first
            let eventID = try calendarService.addPlan(
                snapshot.plans[index],
                to: calendarID
            )
            snapshot.plans[index].externalCalendarID = calendarID
            snapshot.plans[index].externalEventID = eventID
            snapshot.plans[index].updatedAt = .now
            await refreshCalendarEvents()
            await persist()
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 캘린더에 추가하지 못했습니다. \(error.localizedDescription)",
                english: "Could not add the plan to Calendar. \(error.localizedDescription)"
            )
        }
    }

    func movePlan(_ planID: UUID, by delta: TimeInterval) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        do {
            let moved = try ScheduleEditEngine.move(
                snapshot.plans[index],
                by: delta
            )
            if let parentID = moved.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (moved.span.start < parent.span.start
                   || moved.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }

            let descendants = try PlanHierarchy.descendants(
                of: planID,
                in: snapshot.plans
            )
            let appliedDelta = moved.span.start.timeIntervalSince(
                snapshot.plans[index].span.start
            )
            let previous = snapshot
            snapshot.plans[index] = moved
            for descendant in descendants {
                guard let childIndex = snapshot.plans.firstIndex(where: {
                    $0.id == descendant.id
                }) else {
                    continue
                }
                snapshot.plans[childIndex] = try ScheduleEditEngine.move(
                    descendant,
                    by: appliedDelta
                )
            }
            snapshot.plans.sort { $0.span.start < $1.span.start }
            scheduleUserEditSave(
                from: previous,
                coalescingKey: "plan:\(planID.uuidString)"
            )
        } catch PlanningError.fixedPlan {
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더의 고정 일정은 이곳에서 옮길 수 없습니다.",
                english: "Fixed calendar events cannot be moved here."
            )
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "하위 계획은 상위 루틴 기간 안에서만 옮길 수 있습니다.",
                english: "A sub-plan can only be moved within its parent routine's period."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 옮기지 못했습니다.",
                english: "Could not move the plan."
            )
        }
    }

    func resizePlan(
        _ planID: UUID,
        startDelta: TimeInterval? = nil,
        endDelta: TimeInterval? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        let plan = snapshot.plans[index]
        do {
            let resized = try ScheduleEditEngine.resize(
                plan,
                newStart: startDelta.map {
                    plan.span.start.addingTimeInterval($0)
                },
                newEnd: endDelta.map {
                    plan.span.end.addingTimeInterval($0)
                }
            )
            if let parentID = resized.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (resized.span.start < parent.span.start
                   || resized.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(of: planID, in: snapshot.plans)
            guard children.allSatisfy({
                resized.span.start <= $0.span.start
                    && $0.span.end <= resized.span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            let previous = snapshot
            snapshot.plans[index] = resized
            scheduleUserEditSave(
                from: previous,
                coalescingKey: "plan:\(planID.uuidString)"
            )
        } catch PlanningError.childOutsideParent {
            userFacingError = AppLanguagePreference.text(
                korean: "상위·하위 계획의 기간을 벗어나지 않도록 길이를 조절해 주세요.",
                english: "Adjust the length so it stays within the period of the parent and child plans."
            )
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획 길이를 조절하지 못했습니다.",
                english: "Could not adjust the plan length."
            )
        }
    }

    @discardableResult
    func addCustomCategory(
        name: String,
        icon: CategoryIcon,
        lightHex: String
    ) -> CategoryDefinition? {
        guard acceptsDataMutation() else { return nil }
        do {
            let category = try CategoryCatalog.makeCustom(
                name: name,
                icon: icon,
                lightHex: lightHex,
                existing: snapshot.categories
            )
            snapshot.categories.append(category)
            snapshot.categories.sort { $0.sortOrder < $1.sortOrder }
            Task { await persist() }
            return category
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 추가하지 못했습니다. \(error.localizedDescription)",
                english: "Could not add the major category. \(error.localizedDescription)"
            )
            return nil
        }
    }

    func updateCategory(
        _ categoryID: String,
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        hidden: Bool
    ) {
        guard let index = snapshot.categories.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !snapshot.categories.contains(where: {
            $0.id != categoryID
                && $0.name.localizedCaseInsensitiveCompare(cleanName)
                    == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 대분류가 이미 있습니다.",
                english: "A major category with the same name already exists."
            )
            return
        }
        do {
            snapshot.categories[index] = try CategoryCatalog.update(
                snapshot.categories[index],
                name: cleanName,
                icon: icon,
                lightHex: lightHex,
                hidden: hidden
            )
            Task { await persist() }
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 수정하지 못했습니다. \(error.localizedDescription)",
                english: "Could not edit the major category. \(error.localizedDescription)"
            )
        }
    }

    func moveCategory(_ categoryID: String, by offset: Int) {
        let sorted = snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        guard let index = sorted.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let destination = index + offset
        guard sorted.indices.contains(destination) else { return }
        var orderedIDs = sorted.map(\.id)
        orderedIDs.swapAt(index, destination)
        applyCategoryOrder(orderedIDs)
    }

    func moveCategories(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        snapshot.categories = CategoryCatalog.moving(
            snapshot.categories,
            fromOffsets: source,
            toOffset: destination
        )
        Task { await persist() }
    }

    private func applyCategoryOrder(_ orderedIDs: [String]) {
        snapshot.categories = CategoryCatalog.reordered(
            snapshot.categories,
            orderedIDs: orderedIDs
        )
        Task { await persist() }
    }

    func setTimelineRowOrder(_ orderedIDs: [String]) {
        let normalized = AppFeatureSettings.normalizedTimelineRowOrder(
            orderedIDs
        )
        guard snapshot.settings.timelineRowOrder != normalized else {
            return
        }
        snapshot.settings.timelineRowOrder = normalized
        Task { await persist() }
    }

    func deleteCustomCategory(
        _ categoryID: String,
        reassigningTo replacementID: String
    ) {
        do {
            let result = try CategoryCatalog.deleting(
                categoryID: categoryID,
                reassigningTo: replacementID,
                categories: snapshot.categories,
                plans: snapshot.plans,
                actuals: snapshot.actuals
            )
            snapshot.categories = result.categories
            snapshot.plans = result.plans
            snapshot.actuals = result.actuals
            Task { await persist() }
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 삭제하지 못했습니다. \(error.localizedDescription)",
                english: "Could not delete the major category. \(error.localizedDescription)"
            )
        }
    }
}
