import Foundation

/// 분류 규칙이 바뀐 뒤 지난 날짜 전체를 뒤에서 한 번 다시 만든다(HMM1101A01).
/// 앱이 앞에 있고 다른 하루 갱신이 없을 때만 하루씩, 사이를 두고 처리한다.
extension AppModel {
    static let classificationBackfillStartDelay: Duration = .seconds(30)
    static let classificationBackfillDayPause: Duration = .seconds(2)

    /// 앱이 앞으로 올 때 부른다. 이미 돌고 있거나 이 버전을 끝냈으면 아무것도 하지 않는다.
    /// 앱이 뒤로 가면 다음 날 앞에서 멈추고, 다음에 앞으로 올 때 이어 한다.
    func scheduleClassificationBackfill() {
        guard classificationBackfillTask == nil, let store = daySealStore,
              let markers = classificationRecompute?.markers else { return }
        classificationBackfillTask = Task(priority: .utility) { @MainActor [weak self] in
            defer { self?.classificationBackfillTask = nil }
            let backfill = ClassificationBackfill(markers: markers)
            guard await !backfill.isFinished() else { return }
            try? await Task.sleep(for: Self.classificationBackfillStartDelay)
            guard !Task.isCancelled, let days = try? await store.dataUTCDays() else { return }
            _ = await backfill.run(
                days: Self.localDays(fromUTCDayNumbers: days),
                shouldContinue: { [weak self] in await self?.waitForClassificationBackfillTurn() ?? false },
                recompute: { [weak self] day in await self?.recomputeDayForBackfill(day) ?? false }
            )
        }
    }

    /// UTC 날짜 번호 하나는 지역 시각으로 이틀에 걸칠 수 있어 양 끝의 날을 모두 넣는다.
    static func localDays(fromUTCDayNumbers numbers: [Int], calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        Array(Set(numbers.flatMap { number -> [Date] in
            let start = Date(timeIntervalSince1970: Double(number) * 86_400)
            return [calendar.startOfDay(for: start), calendar.startOfDay(for: start.addingTimeInterval(86_399))]
        }))
    }

    /// 쉬었다가, 화면의 하루 갱신이 끝날 때까지 기다린다. 앱이 뒤로 가거나 데이터를 바꿀 수 없으면 멈춘다.
    private func waitForClassificationBackfillTurn() async -> Bool {
        try? await Task.sleep(for: Self.classificationBackfillDayPause)
        while !Task.isCancelled, isSceneActive, acceptsDataMutation(),
              isSensorTimelineRefreshing || sensorTimelineTask != nil {
            try? await Task.sleep(for: .seconds(1))
        }
        return !Task.isCancelled && isSceneActive && acceptsDataMutation()
    }

    /// 보통 하루 갱신과 같은 길로 다시 만들고 저장한다. 원본은 읽기만 한다.
    private func recomputeDayForBackfill(_ day: Date) async -> Bool {
        guard await refreshSensorTimeline(containing: day), !Task.isCancelled else { return false }
        await relabelWatchNaps(on: day)
        guard await persist() else { return false }
        // 확정해 둔 요약은 예전 규칙으로 만든 것이라 새 기록으로 다시 확정한다.
        if sealedDay(for: day) != nil {
            await removeSeal(for: day)
            await sealDay(day)
        }
        return true
    }

    /// 건강 앱 갱신 범위(최근 31일) 밖의 지난 날에도 Apple Watch 낮잠을 붙인다.
    private func relabelWatchNaps(on day: Date) async {
        guard settings.healthEnabled else { return }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let night = SleepAnalysisEngine.overnightSpan(containing: start, calendar: calendar)
        guard let sessions = try? await healthService.sleepSessions(in: TimeSpan(start: night.start, end: end)),
              !Task.isCancelled, acceptsDataMutation() else { return }
        let labeled = AppleWatchNapPolicy.labeling(
            snapshot.actuals, sessions: sessions, inside: TimeSpan(start: start, end: end)
        )
        if labeled != snapshot.actuals { snapshot.actuals = labeled }
    }
}
