import Foundation
import TaptionPlanCore

extension AppModel {
    func selectTab(_ tab: RootTab) {
        if TaptionProductScope.automaticLoggingOnly, tab == .goals {
            selectedTab = .schedule
            detail = nil
            groupNavigationPath = []
            return
        }
        if tab == .review, reviewScale != .day {
            reviewScale = .day
        }
        selectedTab = tab
        detail = nil
        groupNavigationPath = []
        if tab == .schedule || tab == .review {
            // Selecting the same root tab is common while the timeline is
            // already visible. The integration gate below keeps that UI
            // action from rereading the same HealthKit/location window.
            Task { await refreshConnectedRecordsNow(force: false) }
        }
    }

    func openGroup(_ planID: UUID) {
        if groupNavigationPath.last != planID {
            if let current = groupNavigationPath.last,
               snapshot.plans.contains(where: {
                   $0.id == planID && $0.parentID == current
               }) {
                groupNavigationPath.append(planID)
            } else {
                groupNavigationPath = [planID]
            }
        }
        selectedGroupPlanID = planID
        detail = .group
    }

    func openGoalDetail(_ planID: UUID) {
        guard snapshot.plans.contains(where: { $0.id == planID }) else { return }
        selectedGoalPlanID = planID
        selectedGroupPlanID = nil
        groupNavigationPath = []
        detail = .goal
    }

    func closeGoalDetail() {
        selectedGoalPlanID = nil
        detail = nil
    }

    func closeCurrentGroup() {
        if groupNavigationPath.count > 1 {
            groupNavigationPath.removeLast()
            selectedGroupPlanID = groupNavigationPath.last
            detail = .group
        } else {
            groupNavigationPath = []
            selectedGroupPlanID = nil
            detail = nil
        }
    }

    func selectScale(_ scale: TimeScale) {
        let scheduleScale = scale.scheduleEquivalent
        guard selectedScale != scheduleScale else { return }
        selectedScale = scheduleScale
        scheduleCalendarStoreRefresh()
        if settings.rememberLastScale {
            snapshot.settings.startScale = scheduleScale.timelineLevel
        }
        // Only the visible EventKit window changes with scale. Sensor and
        // app-usage sources remain untouched.
        if settings.rememberLastScale {
            Task { await persist() }
        }
    }

    func shiftSelectedDate(by direction: Int) {
        guard canShiftSelectedDate(by: direction),
              let targetDate = TimelinePeriodNavigationEngine()
                .adjacentDate(
                    from: selectedDate,
                    level: selectedScale.timelineLevel,
                    direction: direction
                ) else {
            return
        }
        selectedDate = targetDate
    }

    /// 기록 탭은 시간표와 배율이 따로다. 원형 시간표를 옆으로 넘길 때는
    /// 기록 배율을 쓰되 데이터 경계는 시간표와 똑같이 지킨다.
    func shiftReviewDate(by direction: Int) {
        let navigation = TimelinePeriodNavigationEngine()
        let level = reviewScale.timelineLevel
        guard navigation.canNavigate(
            from: selectedDate,
            level: level,
            direction: direction,
            snapshot: snapshot
        ),
            let targetDate = navigation.adjacentDate(
                from: selectedDate,
                level: level,
                direction: direction
            ) else {
            return
        }
        selectedDate = targetDate
    }

    func canShiftSelectedDate(by direction: Int) -> Bool {
        TimelinePeriodNavigationEngine().canNavigate(
            from: selectedDate,
            level: selectedScale.timelineLevel,
            direction: direction,
            snapshot: snapshot
        )
    }

    func returnToNow() {
        let wasToday = Calendar.autoupdatingCurrent.isDateInToday(selectedDate)
        selectedDate = .now
        if wasToday { scheduleSelectedDateRefresh() }
    }

    func scheduleSelectedDateRefresh() {
        guard isSceneActive else { return }
        selectedDateRefreshGeneration &+= 1
        let generation = selectedDateRefreshGeneration
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.selectedDateRefreshGeneration == generation {
                    self.selectedDateRefreshTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
                while self.isRefreshingIntegrations {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                return
            }
            guard self.selectedDateRefreshGeneration == generation,
                  self.isSceneActive else { return }
            let selectedDate = self.selectedDate
            await self.refreshEnabledData(
                dataSpan: self.daySpan(containing: selectedDate),
                healthSpan: SleepAnalysisEngine.overnightSpan(
                    containing: selectedDate
                ),
                force: false
            )
        }
    }

    /// 위젯·알림·URL에서 들어온 링크를 지도 홈의 상태로 번역한다.
    ///
    /// 예전에는 `selectedTab`을 바꿨지만 지도 우선 화면에는 탭이 없다. 지금은
    /// 날짜를 옮기고 `pendingMapHomeRoute`에 "무엇을 열지"를 남긴다.
    func openDeepLink(_ url: URL) async {
        guard let link = TaptionDeepLink(url: url) else { return }
        let planStart: Date?
        if case .plan(let planID) = link {
            planStart = await planForDeepLink(planID)?.span.start
        } else {
            planStart = nil
        }
        let destination = link.mapHomeDestination(
            planStart: planStart,
            now: .now
        )
        selectedTab = .schedule
        selectedScale = .day
        selectedDate = destination.date
        detail = nil
        selectedAction = nil
        pendingMapHomeRoute = destination.route
        publishWidgetPayload()
        // 위젯·알림 딥링크는 화면이 실제로 움직였는지 확인할 방법이 없었다.
        // 라우팅 결과를 남겨 두면 다음에 "링크가 안 먹는다"는 말이 나올 때
        // 파싱 실패인지 화면 이동 실패인지 로그만 보고 가를 수 있다.
        TaptionPlanDiagnosticsLogger.shared.record(
            "deep_link_routed",
            fields: [
                "host": url.host ?? "",
                "route": destination.route.diagnosticName,
                "plan_found": String(planStart != nil),
            ]
        )
    }

    private func planForDeepLink(_ planID: UUID) async -> PlanRecord? {
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        guard var loaded = try? await repository.load() else {
            return nil
        }
        guard let prepared = try? await Self.preparedLoadedSnapshotInBackground(
            loaded
        ) else { return nil }
        loaded = prepared
        snapshot = loaded
        publishWidgetPayload()
        return snapshot.plans.first { $0.id == planID }
    }
}
