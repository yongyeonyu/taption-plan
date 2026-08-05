import SwiftUI

struct GoalsView: View {
    @Bindable var model: AppModel

    private var goals: [GoalCard] {
        let roots = GoalRecordPolicy.visibleGoals(in: model.snapshot.plans)

        let aggregation = TimelineAggregationEngine()
        return roots.map { plan in
            let descendants =
                (try? PlanHierarchy.descendants(
                    of: plan.id,
                    in: model.snapshot.plans
                )) ?? []
            let repeatSegmentCount = descendants.filter {
                $0.origin == .repeatRule
            }.count
            let manualChildCount = descendants.count - repeatSegmentCount
            let rollup = try? aggregation.rollup(
                goalID: plan.id,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals
            )
            let planned = rollup?.plannedDuration ?? plan.span.duration
            let actual = rollup?.actualDuration ?? 0
            let progress = planned > 0
                ? min(1, max(0, actual / planned))
                : 0
            return GoalCard(
                id: plan.id,
                planID: plan.id,
                title: goalDisplayTitle(plan.title),
                period: periodText(plan.span),
                leftDetail: goalLeftDetail(
                    manualChildCount: manualChildCount,
                    repeatSegmentCount: repeatSegmentCount
                ),
                rightDetail: "실제 \(durationText(actual)) / 계획 \(durationText(planned))",
                repeatSummary: GoalRepeatRuleFormatter.summary(
                    plan.repeatRules
                ),
                progress: progress,
                category: PlanCategory(categoryID: plan.categoryID)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(title: "루틴", trailing: "")

            List {
                if goals.isEmpty {
                    emptyGoalState
                        .goalListRow()
                }

                ForEach(goals) { goal in
                    goalCardView(goal)
                        .goalListRow()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteGoal(goal)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                editGoal(goal)
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .tint(Color.tpInk)
                        }
                }

            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
        }
    }

    private func goalCardView(_ goal: GoalCard) -> some View {
        let childRows = childTimelineRows(for: goal.planID)
        let repeatSegmentCount = repeatSegmentCount(for: goal.planID)
        return VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(goal.category.darkColor)
                        .frame(width: 10, height: 10)
                    Text(goal.title)
                        .font(.taption(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 4)
                    Text(goal.period)
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color.tpSecondary)
                }

                HStack {
                    if goal.title.contains("운동") {
                        Image(systemName: "heart.text.square")
                            .font(.taption(size: 9))
                    }
                    Text(goal.leftDetail)
                    Spacer(minLength: 4)
                    Text(goal.rightDetail)
                        .fontWeight(.semibold)
                }
                .font(.taption(size: 10.5))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, 8)

                if let repeatSummary = goal.repeatSummary {
                    Label(repeatSummary, systemImage: "repeat")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.66))
                        .lineLimit(2)
                        .padding(.top, 5)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(red: 0.93, green: 0.93, blue: 0.94))
                        Capsule()
                            .fill(goal.category.darkColor)
                            .frame(width: proxy.size.width * goal.progress)
                    }
                }
                .frame(height: 6)
                .padding(.top, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let planID = goal.planID {
                    model.openGoalDetail(planID)
                }
            }

            goalTimelineSection(
                rows: childRows,
                category: goal.category,
                repeatSegmentCount: repeatSegmentCount
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .draftCard()
    }

    private func deleteGoal(_ goal: GoalCard) {
        guard let planID = goal.planID else { return }
        Task { await model.deletePlan(planID) }
    }

    private func editGoal(_ goal: GoalCard) {
        guard let planID = goal.planID else { return }
        model.planEditorRequest = PlanEditorRequest(id: planID)
    }

    private var emptyGoalState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("아직 루틴이 없습니다")
                .font(.taption(size: 12.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text("새 루틴을 추가하거나 상황별 루틴을 만들 수 있습니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.6)
        }
    }

    @ViewBuilder
    private func goalTimelineSection(
        rows: [GoalChildPlanRow],
        category: PlanCategory,
        repeatSegmentCount: Int
    ) -> some View {
        if !rows.isEmpty || repeatSegmentCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("계획 타임라인")
                        .font(.taption(size: 9, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)

                    Spacer(minLength: 4)

                    if let summary = childTimelineSummary(
                        rows,
                        repeatSegmentCount: repeatSegmentCount
                    ) {
                        Text(summary)
                            .font(.taption(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.tpInk.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                ForEach(rows) { row in
                    GoalChildPlanRowView(
                        row: row,
                        category: category
                    ) {
                        model.planEditorRequest = PlanEditorRequest(id: row.id)
                    }
                }

                if repeatSegmentCount > 0 {
                    Label(
                        "반복 세그먼트 \(repeatSegmentCount)개는 시간표 간트에 표시됩니다.",
                        systemImage: "rectangle.split.3x1"
                    )
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(red: 0.965, green: 0.965, blue: 0.975),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
        } else {
            Text("아직 계획이 없습니다. ‘+’로 하위 계획을 추가하세요.")
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private func childPlans(for goalID: UUID?) -> [PlanRecord] {
        guard let goalID else { return [] }
        return PlanHierarchy.children(of: goalID, in: model.snapshot.plans)
            .filter { $0.origin != .repeatRule }
            .sorted { $0.span.start < $1.span.start }
    }

    private func repeatSegmentCount(for goalID: UUID?) -> Int {
        guard let goalID else { return 0 }
        return ((try? PlanHierarchy.descendants(
            of: goalID,
            in: model.snapshot.plans
        )) ?? [])
        .filter { $0.origin == .repeatRule }
        .count
    }

    private func childTimelineRows(for goalID: UUID?) -> [GoalChildPlanRow] {
        let plans = childPlans(for: goalID)
        let duplicateGroups = Dictionary(
            grouping: plans,
            by: childPlanDuplicateKey
        )
        var duplicateOrdinals: [UUID: Int] = [:]

        for group in duplicateGroups.values where group.count > 1 {
            for (index, plan) in group.sorted(by: childPlanSort).enumerated() {
                duplicateOrdinals[plan.id] = index + 1
            }
        }

        return plans.map { plan in
            let key = childPlanDuplicateKey(plan)
            let duplicateCount = duplicateGroups[key]?.count ?? 1
            let overlapCount = plans.filter { other in
                other.id != plan.id
                    && plan.span.intersection(with: other.span) != nil
            }.count

            return GoalChildPlanRow(
                id: plan.id,
                title: plan.title,
                timeText: childPlanTimeText(plan.span),
                detailText: childPlanDetailText(plan),
                duplicateCount: duplicateCount,
                duplicateOrdinal: duplicateOrdinals[plan.id],
                overlapCount: overlapCount
            )
        }
    }

    private func childTimelineSummary(
        _ rows: [GoalChildPlanRow],
        repeatSegmentCount: Int
    ) -> String? {
        let duplicateCount = rows.filter(\.isDuplicate).count
        let overlapCount = rows.filter(\.hasOverlap).count
        let parts = [
            repeatSegmentCount > 0 ? "반복 \(repeatSegmentCount)개" : nil,
            duplicateCount > 0 ? "중복 \(duplicateCount)건" : nil,
            overlapCount > 0 ? "겹침 \(overlapCount)건" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func goalLeftDetail(
        manualChildCount: Int,
        repeatSegmentCount: Int
    ) -> String {
        if repeatSegmentCount > 0 {
            let manualText = manualChildCount > 0
                ? " · 계획 \(manualChildCount)개"
                : ""
            return "반복 세그먼트 \(repeatSegmentCount)개\(manualText)"
        }
        return "하위 \(manualChildCount)개 · 월→주→일"
    }

    private func childPlanDuplicateKey(_ plan: PlanRecord) -> String {
        plan.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func childPlanSort(_ lhs: PlanRecord, _ rhs: PlanRecord) -> Bool {
        if lhs.span.start == rhs.span.start {
            return lhs.span.end < rhs.span.end
        }
        return lhs.span.start < rhs.span.start
    }

    private func childPlanTimeText(_ span: TimeSpan) -> String {
        let start = span.start.formatted(.dateTime.hour().minute())
        let end = span.end.formatted(.dateTime.hour().minute())
        return "\(start)~\(end)"
    }

    private func childPlanDetailText(_ plan: PlanRecord) -> String {
        let parts = [
            plan.middleCategoryName,
            plan.subCategoryName,
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return PlanCategory(categoryID: plan.categoryID).rawValue
    }

    private func periodText(_ span: TimeSpan) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(span.start, equalTo: span.end, toGranularity: .month) {
            return span.start.formatted(.dateTime.month().day())
                + " – "
                + span.end.formatted(.dateTime.day())
        }
        return span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.formatted(.dateTime.month().day())
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private func goalDisplayTitle(_ raw: String) -> String {
        GoalRecordPolicy.displayTitle(raw)
    }
}

enum GoalDetailMode: Equatable {
    case habit
    case project
    case empty
}

struct GoalHabitDay: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var planned: TimeInterval
    var actual: TimeInterval
}

struct GoalDetailSnapshot: Equatable {
    var mode: GoalDetailMode
    var descendants: [PlanRecord]
    var actualMatches: [GoalActualMatch]
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var weekDays: [GoalHabitDay]
    var missedDays: [GoalHabitDay]
    var nextPlan: PlanRecord?
    var upcomingPlans: [PlanRecord]
    var blockerMemos: [ActionMemo]
    var fourWeekActuals: [TimeInterval]
    var evidence: [String]
}

enum GoalDetailEngine {
    static func make(
        goal: PlanRecord,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        memos: [ActionMemo] = [],
        referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> GoalDetailSnapshot {
        let descendants = (try? PlanHierarchy.descendants(
            of: goal.id,
            in: plans
        )) ?? []
        let hasRepeat = goal.repeatRules?.isEmpty == false
            || descendants.contains(where: { $0.origin == .repeatRule })
        let manualChildren = descendants.filter { $0.origin != .repeatRule }
        let mode: GoalDetailMode = hasRepeat
            ? .habit
            : manualChildren.isEmpty ? .empty : .project
        let scopedIDs = Set([goal.id] + descendants.map(\.id))
        let actualMatches = GoalActivityMatchingEngine.matches(
            goal: goal,
            plans: plans,
            actuals: actuals,
            asOf: referenceDate
        )
        let scopedActuals = actualMatches.map(\.actual)
        let plannedLeaves = descendants.isEmpty
            ? [goal]
            : descendants.filter { child in
                !descendants.contains(where: { $0.parentID == child.id })
            }
        let plannedDuration = unionDuration(plannedLeaves.map(\.span))
        let actualDuration = unionDuration(
            scopedActuals.map { $0.span(asOf: referenceDate) }
        )
        let week = calendar.dateInterval(
            of: .weekOfYear,
            for: referenceDate
        ) ?? DateInterval(
            start: calendar.startOfDay(for: referenceDate),
            duration: 7 * 86_400
        )
        let weekDays = (0..<7).compactMap { offset -> GoalHabitDay? in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: week.start
            ) else { return nil }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)
                ?? date.addingTimeInterval(86_400)
            let day = TimeSpan(start: date, end: dayEnd)
            return GoalHabitDay(
                date: date,
                planned: unionDuration(
                    plannedLeaves.compactMap { $0.span.intersection(with: day) }
                ),
                actual: unionDuration(
                    scopedActuals.compactMap {
                        $0.span(asOf: referenceDate).intersection(with: day)
                    }
                )
            )
        }
        let fourWeekActuals = (0..<4).reversed().map { offset in
            let end = calendar.date(
                byAdding: .weekOfYear,
                value: 1 - offset,
                to: week.start
            ) ?? week.end
            let start = calendar.date(
                byAdding: .day,
                value: -7,
                to: end
            ) ?? end.addingTimeInterval(-7 * 86_400)
            let span = TimeSpan(start: start, end: end)
            return unionDuration(
                scopedActuals.compactMap {
                    $0.span(asOf: referenceDate).intersection(with: span)
                }
            )
        }
        let upcomingPlans = descendants
            .filter { $0.span.end >= referenceDate && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
        let nextPlan = upcomingPlans.first
        let blockerMemos = memos
            .filter {
                $0.planID.map(scopedIDs.contains) == true
                    && $0.kind == .blocker
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.createdAt > $1.createdAt }
        let missedDays = weekDays.filter {
            $0.planned > 0 && $0.actual < 60
        }
        let evidence = Array(Set(scopedActuals.map { actual in
            switch actual.source {
            case .healthKit: "HealthKit"
            case .appleWatch: "Apple Watch"
            case .motion: "iPhone Core Motion"
            case .location: "iPhone 위치·센서"
            case .timer: "앱 타이머"
            case .manual: "직접 기록"
            case .calendar: "캘린더"
            case .photo: "사진"
            case .media: "미디어 재생"
            case .call: "통화"
            case .appUsage: "앱 사용시간"
            }
        })).sorted()
        return GoalDetailSnapshot(
            mode: mode,
            descendants: descendants,
            actualMatches: actualMatches,
            plannedDuration: plannedDuration,
            actualDuration: actualDuration,
            weekDays: weekDays,
            missedDays: missedDays,
            nextPlan: nextPlan,
            upcomingPlans: Array(upcomingPlans.prefix(3)),
            blockerMemos: Array(blockerMemos.prefix(3)),
            fourWeekActuals: fourWeekActuals,
            evidence: evidence
        )
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

/// Two-handle interval control used by routine details.  The striped track is
/// the plan and the solid track is the portion actually performed.
private struct RoutineTimeRangeSlider: View {
    let plan: PlanRecord
    let actual: ActualRecord?
    let onCommit: (Date, Date) -> Void

    @State private var actualStart: Date
    @State private var actualEnd: Date

    private let minimumDuration: TimeInterval = 5 * 60

    init(
        plan: PlanRecord,
        actual: ActualRecord?,
        onCommit: @escaping (Date, Date) -> Void
    ) {
        self.plan = plan
        self.actual = actual
        self.onCommit = onCommit
        let start = actual?.startedAt ?? plan.span.start
        _actualStart = State(initialValue: start)
        _actualEnd = State(
            initialValue: actual?.endedAt ?? start.addingTimeInterval(5 * 60)
        )
    }

    private var plannedDuration: TimeInterval { plan.span.duration }
    private var actualDuration: TimeInterval {
        max(0, actualEnd.timeIntervalSince(actualStart))
    }
    private var isLocked: Bool {
        actual.map(AutomaticRecordTimelineEngine.isImmutable) ?? false
    }
    private var progress: Double {
        guard plannedDuration > 0 else { return 0 }
        return min(1, actualDuration / plannedDuration)
    }
    private var status: (String, Color, String) {
        if actual == nil && actualDuration <= minimumDuration {
            return ("미완료", Color.tpSecondary, "circle")
        }
        if progress >= 0.999 {
            return ("완료", .green, "checkmark.circle.fill")
        }
        if actualDuration > 0 {
            return ("부분 달성", .orange, "circle.lefthalf.filled")
        }
        return ("미완료", Color.tpSecondary, "circle")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("계획 · \(timeRange(plan.span.start, plan.span.end))")
                Spacer(minLength: 4)
                Label(status.0, systemImage: status.2)
                    .foregroundStyle(status.1)
            }
            .font(.taption(size: 8, weight: .semibold))

            if isLocked {
                Label("자동 기록 · 수정 불가", systemImage: "lock.fill")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.tpLine.opacity(0.55))
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    Color.tpSecondary.opacity(0.22),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                )
                        }

                    Capsule()
                        .fill(PlanCategory(categoryID: plan.categoryID).darkColor.opacity(0.78))
                        .frame(width: actualWidth(width), height: 12)
                        .offset(x: actualX(width))

                    handleControl(
                        at: actualX(width),
                        isStart: true,
                        width: width
                    )
                    handleControl(
                        at: actualX(width) + actualWidth(width),
                        isStart: false,
                        width: width
                    )
                }
                .frame(height: 26)
            }
            .frame(height: 26)

            HStack(spacing: 4) {
                Text("실제 · \(timeRange(actualStart, actualEnd))")
                Text("· \(durationText(actualDuration))")
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(isLocked ? "Apple 건강 기록" : "양끝을 드래그")
                    .foregroundStyle(Color.tpSecondary.opacity(0.82))
            }
            .font(.taption(size: 7.5, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 9))
        .onChange(of: actual?.startedAt) { _, value in
            if let value { actualStart = value }
        }
        .onChange(of: actual?.endedAt) { _, value in
            if let value { actualEnd = value }
        }
    }

    private enum Handle { case start, end }

    private func handle(at x: CGFloat, isStart: Bool) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay {
                Circle().stroke(
                    PlanCategory(categoryID: plan.categoryID).darkColor,
                    lineWidth: 2
                )
            }
            .shadow(color: .black.opacity(0.14), radius: 2)
            .offset(x: x - 11)
            .accessibilityLabel(isStart ? "실제 시작 시간" : "실제 종료 시간")
    }

    @ViewBuilder
    private func handleControl(
        at x: CGFloat,
        isStart: Bool,
        width: CGFloat
    ) -> some View {
        if isLocked {
            handle(at: x, isStart: isStart)
                .opacity(0.42)
                .accessibilityHint("자동 기록은 수정할 수 없습니다")
        } else {
            handle(at: x, isStart: isStart)
                .gesture(handleGesture(isStart ? .start : .end, width: width))
        }
    }

    private func handleGesture(_ handle: Handle, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let date = date(at: value.location.x, width: width)
                switch handle {
                case .start:
                    actualStart = min(
                        max(plan.span.start, date),
                        actualEnd.addingTimeInterval(-minimumDuration)
                    )
                case .end:
                    actualEnd = max(
                        min(plan.span.end, date),
                        actualStart.addingTimeInterval(minimumDuration)
                    )
                }
            }
            .onEnded { _ in
                onCommit(actualStart, actualEnd)
            }
    }

    private func fraction(_ date: Date) -> CGFloat {
        guard plannedDuration > 0 else { return 0 }
        return CGFloat(
            min(1, max(0, date.timeIntervalSince(plan.span.start) / plannedDuration))
        )
    }

    private func actualX(_ width: CGFloat) -> CGFloat { fraction(actualStart) * width }

    private func actualWidth(_ width: CGFloat) -> CGFloat {
        max(10, (fraction(actualEnd) - fraction(actualStart)) * width)
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
        let value = min(1, max(0, x / max(1, width)))
        return plan.span.start.addingTimeInterval(plannedDuration * value)
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func durationText(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}

struct GoalDetailView: View {
    @Bindable var model: AppModel
    @State private var inlineMemoText = ""
    @State private var showsDeleteConfirmation = false
    @State private var showsActionLinkSheet = false
    @FocusState private var inlineMemoFocused: Bool

    private var goal: PlanRecord? {
        guard let id = model.selectedGoalPlanID else { return nil }
        return model.snapshot.plans.first { $0.id == id }
    }

    private var detail: GoalDetailSnapshot? {
        goal.map {
            GoalDetailEngine.make(
                goal: $0,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals,
                memos: model.snapshot.memos
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            if let goal, let detail {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 10) {
                        summaryCard(goal: goal, detail: detail)
                        switch detail.mode {
                        case .habit:
                            habitDashboard(goal: goal, detail: detail)
                        case .project:
                            projectRoadmap(goal: goal, detail: detail)
                        case .empty:
                            emptyDashboard(goal: goal)
                        }
                        actionButtons(goal: goal)
                    }
                    .padding(12)
                }
                .background(Color.tpBackground)
            } else {
                ContentUnavailableView(
                    "루틴을 찾을 수 없습니다",
                    systemImage: "scope"
                )
            }
        }
        .onChange(of: model.selectedGoalPlanID) { _, _ in
            inlineMemoText = ""
            inlineMemoFocused = false
        }
        .task(id: model.selectedGoalPlanID) {
            guard model.selectedGoalPlanID != nil else { return }
            await model.refreshConnectedRecordsNow()
        }
        .confirmationDialog(
            "이 루틴을 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("루틴 삭제", role: .destructive) {
                guard let goalID = goal?.id else { return }
                Task {
                    await model.deletePlan(goalID)
                    model.closeGoalDetail()
                }
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("루틴과 연결된 하위 계획이 함께 삭제됩니다.")
        }
        .sheet(isPresented: $showsActionLinkSheet) {
            if let goal {
                GoalActionLinkSheet(model: model, goal: goal)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            Button {
                model.closeGoalDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.taption(size: 15, weight: .bold))
            }
            Text(goal.map { GoalRecordPolicy.displayTitle($0.title) } ?? "루틴 상세")
                .font(.taption(size: 16, weight: .bold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private func summaryCard(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        let progress = detail.plannedDuration > 0
            ? min(1, detail.actualDuration / detail.plannedDuration)
            : 0
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    detail.mode == .habit ? "습관 대시보드" : "루틴 로드맵",
                    systemImage: detail.mode == .habit
                        ? "repeat.circle.fill"
                        : "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.taption(size: 10, weight: .bold))
                Spacer()
                Text(dDayText(goal.span.end))
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            HStack {
                metric("루틴 목표", duration(detail.plannedDuration))
                metric("연결 실적", duration(detail.actualDuration))
                metric("진행", "\(Int(progress * 100))%")
            }
            ProgressView(value: progress)
                .tint(PlanCategory(categoryID: goal.categoryID).darkColor)

            HStack(spacing: 6) {
                Image(systemName: achievementSymbol(progress))
                Text(achievementLabel(progress))
                Spacer()
                if !detail.actualMatches.isEmpty {
                    Text("활동 근거 \(detail.actualMatches.count)건")
                }
            }
            .font(.taption(size: 8.5, weight: .bold))
            .foregroundStyle(achievementColor(progress))

            if detail.actualMatches.isEmpty {
                Text(
                    AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                        goal.categoryID
                    )
                        ? "Apple 건강·Watch 수면 기록은 반복 시간과 겹치면 자동 근거로 반영됩니다."
                        : "실적은 시간표에서 항목을 탭해 루틴 또는 액션에 연결하면 반영됩니다."
                )
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }

            actualEvidenceRows(detail.actualMatches)

            if let repeatSummary = GoalRepeatRuleFormatter.summary(
                goal.repeatRules
            ) {
                Label(
                    "반복 시간 · \(repeatSummary)",
                    systemImage: "clock.arrow.2.circlepath"
                )
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpInk.opacity(0.72))
                .lineLimit(2)
            }

            GoalActionControls(model: model, goal: goal) {
                showsDeleteConfirmation = true
            }
        }
        .padding(12)
        .draftCard()
    }

    private func habitDashboard(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let next = detail.nextPlan {
                Label("다음 실행", systemImage: "clock.badge.checkmark")
                    .font(.taption(size: 10, weight: .bold))
                Text("\(next.span.start.formatted(date: .abbreviated, time: .shortened)) → \(next.span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9, weight: .semibold))
            }
                Text("이번 주 루틴 목표와 연결 실적")
                .font(.taption(size: 10, weight: .bold))
            ForEach(detail.weekDays) { day in
                HStack {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .frame(width: 28, alignment: .leading)
                    Text("목표 \(duration(day.planned))")
                    Spacer()
                    Text("실적 \(duration(day.actual))")
                        .foregroundStyle(day.actual > 0 ? Color.tpInk : Color.tpSecondary)
                }
                .font(.taption(size: 8.5, weight: .semibold))
            }
            if !detail.missedDays.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(
                        "놓친 날 " + detail.missedDays.map {
                            $0.date.formatted(.dateTime.weekday(.abbreviated))
                        }.joined(separator: " · ")
                    )
                }
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("4주 실제 추세")
                .font(.taption(size: 9, weight: .bold))
            HStack(alignment: .bottom, spacing: 8) {
                let maximum = max(detail.fourWeekActuals.max() ?? 1, 1)
                ForEach(Array(detail.fourWeekActuals.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(PlanCategory(categoryID: goal.categoryID).darkColor.opacity(0.7))
                            .frame(height: max(4, 45 * value / maximum))
                        Text("\(index + 1)주")
                            .font(.taption(size: 7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if !detail.evidence.isEmpty {
                Label(
                    detail.evidence.joined(separator: " · "),
                    systemImage: "applewatch"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
            let repeatPlans = detail.descendants
                .filter { $0.origin == .repeatRule }
                .prefix(7)
            let dashboardPlans = repeatPlans.isEmpty
                ? Array(detail.descendants.filter { $0.origin != .repeatRule }.prefix(7))
                : Array(repeatPlans)
            linkedActionRows(dashboardPlans, detail: detail)
        }
        .padding(12)
        .draftCard()
    }

    private func projectRoadmap(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        let manual = detail.descendants.filter { $0.origin != .repeatRule }
        let completedCount = manual.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: 9) {
            Label("루틴 내리기", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.taption(size: 10, weight: .bold))
            if !manual.isEmpty {
                Text("연결 액션 \(completedCount)/\(manual.count) 완료")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            ForEach(manual) { plan in
                let actual = matchingActual(for: plan, detail: detail)
                let actualProgress = GoalActivityMatchingEngine.progress(
                    for: plan,
                    matches: detail.actualMatches
                )
                let isComplete = plan.status == .completed
                    || actualProgress >= 0.999
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Button {
                            guard !isComplete else { return }
                            Task {
                                await model.performQuickAction(
                                    .complete,
                                    planID: plan.id
                                )
                            }
                        } label: {
                            Image(systemName: isComplete
                                ? "checkmark.circle.fill"
                                : actualProgress > 0
                                    ? "circle.lefthalf.filled"
                                    : "circle")
                                .font(.taption(size: 11, weight: .bold))
                                .foregroundStyle(
                                    isComplete
                                        ? PlanCategory(categoryID: plan.categoryID).darkColor
                                        : actualProgress > 0
                                            ? Color.orange
                                            : Color.tpSecondary
                                )
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.title)
                                .font(.taption(size: 9, weight: .bold))
                            Text(plan.span.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.taption(size: 7.5))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text(isComplete ? "완료" : actualProgress > 0 ? "부분 달성" : "미달성")
                            .font(.taption(size: 7.5, weight: .bold))
                            .foregroundStyle(
                                isComplete
                                    ? PlanCategory(categoryID: plan.categoryID).darkColor
                                    : actualProgress > 0 ? Color.orange : Color.tpSecondary
                            )
                    }
                    .padding(.leading, indentation(for: plan, in: manual))
                    RoutineTimeRangeSlider(plan: plan, actual: actual) { start, end in
                        Task {
                            await model.updateRoutineActualInterval(
                                planID: plan.id,
                                actualID: actual?.id,
                                startedAt: start,
                                endedAt: end
                            )
                        }
                    }
                    .padding(.leading, indentation(for: plan, in: manual))
                }
            }
            if !detail.upcomingPlans.isEmpty {
                Text("이번 주 실행")
                    .font(.taption(size: 9.5, weight: .bold))
                    .padding(.top, 3)
                ForEach(detail.upcomingPlans) { plan in
                    HStack(spacing: 6) {
                        Image(systemName: plan.status == .completed
                            ? "checkmark.circle.fill"
                            : "circle")
                        Text(plan.title)
                            .lineLimit(1)
                        Spacer()
                        Text(plan.span.start.formatted(.dateTime.month().day()))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .font(.taption(size: 8.5, weight: .semibold))
                }
            }
            if !detail.blockerMemos.isEmpty {
                Label("막힌 메모", systemImage: "exclamationmark.triangle.fill")
                    .font(.taption(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 3)
                ForEach(detail.blockerMemos) { memo in
                    Text(memo.text)
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(2)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(12)
        .draftCard()
    }

    @ViewBuilder
    private func linkedActionRows(
        _ plans: [PlanRecord],
        detail: GoalDetailSnapshot
    ) -> some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("연결 액션")
                    .font(.taption(size: 9.5, weight: .bold))
                    .padding(.top, 2)
                ForEach(plans) { plan in
                    let actual = matchingActual(for: plan, detail: detail)
                    let actualProgress = GoalActivityMatchingEngine.progress(
                        for: plan,
                        matches: detail.actualMatches
                    )
                    let isComplete = plan.status == .completed
                        || actualProgress >= 0.999
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Button {
                                guard !isComplete else { return }
                                Task {
                                    await model.performQuickAction(
                                        .complete,
                                        planID: plan.id
                                    )
                                }
                            } label: {
                                Image(systemName: isComplete
                                    ? "checkmark.circle.fill"
                                    : actualProgress > 0
                                        ? "circle.lefthalf.filled"
                                        : "circle")
                                    .font(.taption(size: 10.5, weight: .bold))
                                    .foregroundStyle(
                                        isComplete
                                            ? PlanCategory(categoryID: plan.categoryID).darkColor
                                            : actualProgress > 0
                                                ? Color.orange
                                                : Color.tpSecondary
                                    )
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(plan.title)
                                    .font(.taption(size: 8.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(plan.span.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.taption(size: 7.5))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            Spacer(minLength: 4)
                            Text(isComplete ? "완료" : actualProgress > 0 ? "부분 달성" : "미달성")
                                .font(.taption(size: 7.5, weight: .bold))
                                .foregroundStyle(
                                    isComplete
                                        ? PlanCategory(categoryID: plan.categoryID).darkColor
                                        : actualProgress > 0 ? Color.orange : Color.tpSecondary
                                )
                        }
                        RoutineTimeRangeSlider(plan: plan, actual: actual) { start, end in
                            Task {
                                await model.updateRoutineActualInterval(
                                    planID: plan.id,
                                    actualID: actual?.id,
                                    startedAt: start,
                                    endedAt: end
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func matchingActual(
        for plan: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> ActualRecord? {
        detail.actualMatches.first(where: {
            $0.actual.planID == plan.id
                || $0.actual.routineID == plan.id
                || $0.matchedPlanID == plan.id
        })?.actual
    }

    private func emptyDashboard(goal: PlanRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("첫 실행 계획이 필요합니다", systemImage: "flag.checkered")
                .font(.taption(size: 10, weight: .bold))
            Text("루틴을 월·주·일 계획으로 내려보내면 실제 기록이 다시 이 루틴으로 합쳐집니다.")
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
            Button("첫 하위 계획 만들기") {
                presentChildPlan(for: goal.id)
            }
            .font(.taption(size: 9, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(.tpInk)
        }
        .padding(12)
        .draftCard()
    }

    private func actionButtons(goal: PlanRecord) -> some View {
        VStack(spacing: 7) {
            Button {
                presentChildPlan(for: goal.id)
            } label: {
                Label("하위 계획 내리기", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.tpInk)
            Button {
                showsActionLinkSheet = true
            } label: {
                Label("기존 액션아이템 연결", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            HStack {
                Button("시간표에서 보기") { model.openGroup(goal.id) }
                Button("반복 설정") {
                    model.planEditorRequest = PlanEditorRequest(id: goal.id)
                }
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 5) {
                Label("메모", systemImage: "note.text")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                InlineMemoField(
                    model: model,
                    planID: goal.id,
                    text: $inlineMemoText,
                    isFocused: $inlineMemoFocused
                )
            }
        }
    }

    private func presentChildPlan(for goalID: UUID) {
        model.addPlanContext = .child(goalID)
        model.isAddPlanPresented = true
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Color.tpSecondary)
            Text(value).fontWeight(.bold)
        }
        .font(.taption(size: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actualEvidenceRows(_ matches: [GoalActualMatch]) -> some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("활동 근거")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                ForEach(Array(matches.prefix(3))) { match in
                    let isLocked = AutomaticRecordTimelineEngine.isImmutable(
                        match.actual
                    )
                    HStack(spacing: 6) {
                        Image(systemName: isLocked
                            ? "lock.fill"
                            : match.actual.endedAt == nil
                                ? "clock.fill"
                                : "checkmark.circle.fill")
                            .font(.taption(size: 8.5, weight: .bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.actual.title)
                                .font(.taption(size: 8.5, weight: .semibold))
                                .lineLimit(1)
                            Text(
                                "\(match.kind.displayName) · "
                                    + evidenceSource(match.actual.source)
                                    + " · "
                                    + match.actual.startedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                            )
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer(minLength: 4)
                        Text(isLocked ? "자동 기록 · 수정 불가" :
                            match.actual.endedAt == nil ? "진행 중" : "기록")
                            .font(.taption(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func evidenceSource(_ source: ActualSource) -> String {
        switch source {
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch"
        case .motion: "iPhone Core Motion"
        case .location: "iPhone 센서"
        case .timer: "앱 타이머"
        case .manual: "직접 기록"
        case .calendar: "캘린더"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func achievementLabel(_ progress: Double) -> String {
        if progress >= 0.999 { return "완료" }
        if progress > 0 { return "부분 달성" }
        return "미달성"
    }

    private func achievementSymbol(_ progress: Double) -> String {
        if progress >= 0.999 { return "checkmark.circle.fill" }
        if progress > 0 { return "circle.lefthalf.filled" }
        return "circle"
    }

    private func achievementColor(_ progress: Double) -> Color {
        if progress >= 0.999 { return .green }
        if progress > 0 { return .orange }
        return Color.tpSecondary
    }

    private func duration(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        return minutes >= 60
            ? "\(minutes / 60)시간 \(minutes % 60)분"
            : "\(minutes)분"
    }

    private func dDayText(_ date: Date) -> String {
        let days = Calendar.autoupdatingCurrent.dateComponents(
            [.day],
            from: Calendar.autoupdatingCurrent.startOfDay(for: .now),
            to: Calendar.autoupdatingCurrent.startOfDay(for: date)
        ).day ?? 0
        return days >= 0 ? "D-\(days)" : "D+\(-days)"
    }

    private func indentation(
        for plan: PlanRecord,
        in plans: [PlanRecord]
    ) -> CGFloat {
        var depth = 0
        var parentID = plan.parentID
        while let id = parentID,
              let parent = plans.first(where: { $0.id == id }) {
            depth += 1
            parentID = parent.parentID
        }
        return CGFloat(min(depth, 3) * 12)
    }
}

struct GoalActionLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let goal: PlanRecord

    private var existingChildIDs: Set<UUID> {
        Set(
            ((try? PlanHierarchy.descendants(
                of: goal.id,
                in: model.snapshot.plans
            )) ?? []).map(\.id)
        )
    }

    private var candidates: [PlanRecord] {
        model.snapshot.plans
            .filter { plan in
                !existingChildIDs.contains(plan.id)
                    && plan.id != goal.id
                    && plan.origin != .repeatRule
                    && !plan.isFixed
                    && plan.status != .skipped
                    && !GoalRecordPolicy.isGoal(plan)
                    && plan.categoryID != "event"
                    && plan.span.intersection(with: goal.span) != nil
            }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.title < rhs.title
                }
                return lhs.span.start < rhs.span.start
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                        ContentUnavailableView(
                        "연결할 액션아이템이 없습니다",
                        systemImage: "link.badge.plus",
                        description: Text("루틴 기간과 겹치는 연결 가능한 액션아이템이 없습니다.")
                    )
                } else {
                    List(candidates) { plan in
                        Button {
                            dismiss()
                            Task {
                                await model.connectActionItem(
                                    plan.id,
                                    toGoal: goal.id
                                )
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "circle")
                                    .font(.taption(size: 11, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title)
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                    Text(
                                        "\(plan.span.start.formatted(date: .abbreviated, time: .shortened))–\(plan.span.end.formatted(date: .omitted, time: .shortened))"
                                    )
                                    .font(.taption(size: 8))
                                    .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "link")
                                    .font(.taption(size: 9, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("액션아이템 연결")
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

/// Goal actions stay in the goal detail surface so the user can operate on
/// the selected goal without opening a second menu or editor first.
struct GoalActionControls: View {
    @Bindable var model: AppModel
    let goal: PlanRecord
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("루틴 제어")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)

            HStack(spacing: 5) {
                Button {
                    Task {
                        if goal.status == .running {
                            await model.pausePlan(goal.id)
                        } else {
                            await model.startPlan(goal.id)
                        }
                    }
                } label: {
                    Label(
                        goal.status == .running ? "정지" : "시작",
                        systemImage: goal.status == .running
                            ? "pause.fill"
                            : "play.fill"
                    )
                }
                .disabled(goal.status == .completed)

                Button {
                    Task {
                        await model.performQuickAction(
                            .complete,
                            planID: goal.id
                        )
                    }
                } label: {
                    Label("완료", systemImage: "checkmark")
                }
                .disabled(goal.status == .completed)

                Button {
                    model.planEditorRequest = PlanEditorRequest(id: goal.id)
                } label: {
                    Label("편집", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(.tpInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.5)
        }
    }
}

struct InlineMemoField: View {
    @Bindable var model: AppModel
    let planID: UUID
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @State private var editingMemoID: UUID?

    var body: some View {
        HStack(spacing: 5) {
            TextField("메모를 입력…", text: $text, axis: .vertical)
                .font(.taption(size: 9.5))
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { save() }
            if memoCount > 0 {
                Text("+\(memoCount)")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.tpProjectDark, in: Capsule())
            }
            HStack(spacing: 3) {
                memoAction("저장", systemImage: "checkmark", enabled: canSave) { save() }
                memoAction("편집", systemImage: "pencil", enabled: latestMemo != nil) { edit() }
                memoAction("삭제", systemImage: "trash", enabled: latestMemo != nil, destructive: true) { delete() }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.5)
        }
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var latestMemo: ActionMemo? {
        model.memos(for: planID).last
    }

    private var memoCount: Int {
        model.memos(for: planID).count
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

    private func edit() {
        guard let memo = latestMemo else { return }
        editingMemoID = memo.id
        text = memo.text
        isFocused.wrappedValue = true
    }

    private func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let editingMemoID {
            model.updateMemo(editingMemoID, text: clean, kind: .idea)
        } else {
            model.addMemo(text: clean, kind: .idea, to: planID)
        }
        reset()
    }

    private func delete() {
        guard let memo = latestMemo else { return }
        model.deleteMemo(memo.id)
        reset()
    }

    private func reset() {
        text = ""
        editingMemoID = nil
        isFocused.wrappedValue = false
    }
}

private struct GoalCard: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let period: String
    let leftDetail: String
    let rightDetail: String
    let repeatSummary: String?
    let progress: CGFloat
    let category: PlanCategory
}

private extension View {
    func goalListRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14)
            )
            .listRowBackground(Color.clear)
    }
}

private struct GoalChildPlanRow: Identifiable {
    let id: UUID
    let title: String
    let timeText: String
    let detailText: String
    let duplicateCount: Int
    let duplicateOrdinal: Int?
    let overlapCount: Int

    var isDuplicate: Bool {
        duplicateCount > 1
    }

    var hasOverlap: Bool {
        overlapCount > 0
    }
}

private struct GoalChildPlanRowView: View {
    let row: GoalChildPlanRow
    let category: PlanCategory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(row.timeText)
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .monospacedDigit()
                    .frame(width: 75, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.taption(size: 8.8, weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(1)

                    Text(row.detailText)
                        .font(.taption(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if row.isDuplicate {
                    badge(
                        "중복 \(row.duplicateOrdinal ?? 1)/\(row.duplicateCount)",
                        fill: Color(red: 0.91, green: 0.87, blue: 0.96),
                        ink: Color(red: 0.37, green: 0.29, blue: 0.54)
                    )
                }

                if row.hasOverlap {
                    badge(
                        "겹침 \(row.overlapCount)",
                        fill: Color(red: 1.0, green: 0.86, blue: 0.77),
                        ink: Color(red: 0.61, green: 0.23, blue: 0.12)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(rowStroke, lineWidth: row.hasOverlap ? 1.1 : 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: Color {
        if row.hasOverlap {
            return Color(red: 1.0, green: 0.95, blue: 0.91)
        }
        if row.isDuplicate {
            return Color(red: 0.97, green: 0.95, blue: 0.99)
        }
        return Color.white.opacity(0.78)
    }

    private var rowStroke: Color {
        if row.hasOverlap {
            return Color(red: 0.88, green: 0.46, blue: 0.26).opacity(0.70)
        }
        if row.isDuplicate {
            return Color(red: 0.52, green: 0.43, blue: 0.68).opacity(0.42)
        }
        return category.darkColor.opacity(0.10)
    }

    private func badge(
        _ title: String,
        fill: Color,
        ink: Color
    ) -> some View {
        Text(title)
            .font(.taption(size: 7.2, weight: .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}

#Preview {
    GoalsView(model: AppModel())
}
