import SwiftUI

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
        HStack(spacing: TaptionSpacing.regular) {
            Button {
                model.closeGoalDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.taption(size: 15, weight: .bold))
            }
            .accessibilityLabel("뒤로")
            Text(goal.map { GoalRecordPolicy.displayTitle($0.title) } ?? "루틴 상세")
                .font(.taption(size: 16, weight: .bold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.tpCard)
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

            HStack(spacing: TaptionSpacing.snug) {
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
                HStack(spacing: TaptionSpacing.compact) {
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
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: TaptionRadius.small))
            }
            Text("4주 실제 추세")
                .font(.taption(size: 9, weight: .bold))
            HStack(alignment: .bottom, spacing: TaptionSpacing.regular) {
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
                VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                    HStack(spacing: TaptionSpacing.cozy) {
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
                        .accessibilityLabel(isComplete ? "완료됨" : "완료로 표시")
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
                    HStack(spacing: TaptionSpacing.snug) {
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
            VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
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
                    VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                        HStack(spacing: TaptionSpacing.cozy) {
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
                            .accessibilityLabel(isComplete ? "완료됨" : "완료로 표시")
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
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
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
            .tint(Color.tpPrimaryFill)
        }
        .padding(12)
        .draftCard()
    }

    private func actionButtons(goal: PlanRecord) -> some View {
        VStack(spacing: TaptionSpacing.cozy) {
            Button {
                presentChildPlan(for: goal.id)
            } label: {
                Label("하위 계획 내리기", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpPrimaryFill)
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

            VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
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
            VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                Text("활동 근거")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                ForEach(Array(matches.prefix(3))) { match in
                    let isLocked = AutomaticRecordTimelineEngine.isImmutable(
                        match.actual
                    )
                    HStack(spacing: TaptionSpacing.snug) {
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
