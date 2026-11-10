@preconcurrency import ActivityKit
import Foundation

enum LiveActivityError: Error, Equatable {
    case unavailable
    case durationExceedsEightHours
    case missingActivity
}

/// 지금 대분류를 외부 화면(다이나믹 아일랜드·잠금화면·워치)에 다시 밀어 주는 주기.
/// 저장·센서 이벤트가 없는 시간 경계에서도 활동 이름이 따라가게 하는 안전망이다.
enum CurrentActivitySyncPolicy {
    static let intervalSeconds = 20
}

enum TaptionCurrentActivityPolicy {
    static func categoryID(
        actuals: [ActualRecord],
        plans: [PlanRecord],
        at date: Date,
        latestSavedAt: Date? = nil,
        latestReading: SensorReading? = nil
    ) -> String? {
        let freshSample = latestSavedAt.flatMap { sample in
            sample <= date && date.timeIntervalSince(sample) <= 90 ? sample : nil
        }
        if let actual = actuals
            .filter({ actual in
                let active = actual.startedAt <= date
                    && (actual.endedAt.map { date < $0 } ?? true)
                let observed = freshSample.map { sample in
                    actual.source.usesAutomaticClassification && !actual.manuallyCorrected
                        && actual.startedAt <= sample
                        && actual.endedAt.map { sample <= $0 } == true
                } ?? false
                return active || observed
            })
            .max(by: {
                let leftConfirmed = $0.manuallyCorrected || $0.source == .manual
                let rightConfirmed = $1.manuallyCorrected || $1.source == .manual
                if leftConfirmed != rightConfirmed { return !leftConfirmed }
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) {
            let category = RecordAnalysisCategoryPolicy.categoryID(for: actual)
            if category == "movement", actual.source.usesAutomaticClassification,
               !actual.manuallyCorrected, let sample = latestReading,
               let savedAt = freshSample, sample.timestamp <= savedAt,
               sample.timestamp > actual.startedAt,
               date.timeIntervalSince(sample.timestamp) <= 90,
               sample.motion == .stationary, sample.motionConfidence == .high,
               sample.speedMetersPerSecond.map({ $0.isFinite && ($0 < 0 || $0 <= 0.5) }) ?? true {
                return "activity"
            }
            return category
        }
        return plans.last(where: {
            $0.status == .running && $0.span.start <= date
        })?.categoryID
    }
}

actor SensorCollectionLiveActivityController {
    static let shared = SensorCollectionLiveActivityController()

    private var activity: Activity<SensorCollectionActivityAttributes>?

    @discardableResult
    func reconcile(
        sessionID: UUID,
        startedAt: Date,
        lastSavedAt: Date?,
        collectionKinds: [String],
        isCollecting: Bool,
        isForeground: Bool,
        intervalSeconds: Int,
        saveToken: Int? = nil,
        isExternalSample: Bool = false,
        latestHeartRate: Double? = nil,
        heartRateUpdatedAt: Date? = nil,
        currentActivityTitle: String? = nil,
        currentActivityCategoryID: String? = nil,
        currentActivitySystemImage: String? = nil,
        currentActivityCatStyle: String? = nil,
        daySummary: SensorCollectionDaySummary? = nil,
        now: Date = .now
    ) async throws -> String? {
        await recoverAndRemoveDuplicates(
            sessionID: sessionID,
            now: now
        )
        let effectiveSaveToken: Int
        if let saveToken {
            effectiveSaveToken = saveToken
        } else {
            effectiveSaveToken = await SensorBackgroundCoordinator.shared.saveToken
        }

        guard isCollecting else {
            await stop(
                lastSavedAt: lastSavedAt,
                collectionKinds: collectionKinds,
                saveToken: effectiveSaveToken,
                now: now
            )
            return nil
        }

        let activityStartedAt = activity?.content.state.startedAt
            ?? (SensorCollectionActivityPolicy.isExpired(
                startedAt: startedAt,
                now: now
            ) ? now : startedAt)
        let previousState = activity?.content.state
        let hasNewSample: Bool
        if let previousState {
            hasNewSample = SensorCollectionActivityPolicy.hasNewSavedSample(
                previousSaveToken: previousState.saveToken,
                currentSaveToken: effectiveSaveToken,
                previousSavedAt: previousState.lastSavedAt,
                currentSavedAt: lastSavedAt
            )
        } else {
            hasNewSample = false
        }
        let phase: SensorCollectionActivityPhase
        if hasNewSample {
            phase = .pulse
        } else if let previousState,
                  previousState.phase == .pulse,
                  !SensorCollectionActivityPolicy.isPhaseExpired(
                      previousState.phase,
                      until: previousState.phaseUntil,
                      now: now
                  ) {
            phase = .pulse
        } else if previousState?.phase == .flatline {
            phase = .flatline
        } else if previousState?.phase == .pulse {
            phase = .flatline
        } else {
            phase = .waiting
        }
        let phaseUntil: Date?
        if hasNewSample {
            phaseUntil = SensorCollectionActivityPolicy.pulseUntil(
                now: now,
                intervalSeconds: intervalSeconds
            )
        } else if phase == .pulse {
            phaseUntil = previousState?.phaseUntil
        } else {
            phaseUntil = nil
        }
        let sensorHUDUntil: Date?
        if hasNewSample {
            sensorHUDUntil = SensorCollectionActivityPolicy.sensorHUDUntil(
                startedAt: now
            )
        } else if let previousHUDUntil = previousState?.sensorHUDUntil,
                  now < previousHUDUntil {
            sensorHUDUntil = previousHUDUntil
        } else if previousState == nil {
            sensorHUDUntil = SensorCollectionActivityPolicy.sensorHUDUntil(
                startedAt: activityStartedAt
            )
        } else {
            sensorHUDUntil = nil
        }
        let salary = SalaryLiveSnapshot.read()
        let activityFrame: Int = hasNewSample
            ? ((previousState?.currentActivityFrame ?? -1) % 6 + 1) % 6
            : (previousState?.currentActivityFrame ?? 0)
        let state = SensorCollectionActivityAttributes.ContentState(
            startedAt: activityStartedAt,
            lastSavedAt: lastSavedAt,
            collectionKinds: collectionKinds,
            isCollecting: true,
            intervalSeconds: intervalSeconds,
            sessionStateRawValue: SensorCollectionSessionState.collecting.rawValue,
            saveToken: effectiveSaveToken,
            phaseRawValue: phase.rawValue,
            phaseUntil: phaseUntil,
            isExternalSample: isExternalSample,
            latestHeartRate: latestHeartRate,
            heartRateUpdatedAt: heartRateUpdatedAt,
            sensorHUDUntil: sensorHUDUntil,
            currentActivityTitle: currentActivityTitle,
            currentActivityCategoryID: currentActivityCategoryID,
            currentActivitySystemImage: currentActivitySystemImage,
            currentActivityCatStyle: currentActivityCatStyle,
            currentActivityFrame: activityFrame,
            salaryText: salary.text,
            salaryBaseSeconds: salary.baseSeconds,
            salaryHourlyRate: salary.hourlyRate,
            salaryMeasuredAt: salary.measuredAt,
            salaryIsWorking: salary.isWorking,
            salaryTickSeconds: salary.tickSeconds,
            salaryCurrencyCode: AppRegion.current.currencyCode,
            daySummary: daySummary
        )
        let staleDate = SensorCollectionActivityPolicy.expirationDate(
            startedAt: activityStartedAt
        )

        if let activity {
            // 표시 값이 그대로면 보내지 않는다. 새 샘플은 saveToken이 바뀌어 여기서 걸러지지 않는다.
            guard SensorCollectionActivityPolicy.shouldPublishUpdate(
                previous: activity.content.state,
                next: state
            ) else { return activity.id }
            await activity.update(
                ActivityContent(state: state, staleDate: staleDate)
            )
            return activity.id
        }

        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        guard SensorCollectionActivityPolicy.canStart(
            isForeground: isForeground,
            intervalSeconds: intervalSeconds,
            activitiesEnabled: activitiesEnabled
        ) else {
            return nil
        }

        let newActivity = try Activity.request(
            attributes: SensorCollectionActivityAttributes(sessionID: sessionID),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil
        )
        activity = newActivity
        return newActivity.id
    }

    func stop(
        lastSavedAt: Date?,
        collectionKinds: [String],
        saveToken: Int? = nil,
        now: Date = .now
    ) async {
        guard let activity else { return }
        let flatlineUntil = SensorCollectionActivityPolicy
            .completionFlatlineUntil(now: now)
        let finalState = SensorCollectionActivityAttributes.ContentState(
            startedAt: activity.content.state.startedAt,
            lastSavedAt: lastSavedAt,
            collectionKinds: collectionKinds,
            isCollecting: false,
            intervalSeconds: activity.content.state.intervalSeconds,
            sessionStateRawValue: SensorCollectionSessionState.stopped.rawValue,
            saveToken: saveToken ?? activity.content.state.saveToken,
            phaseRawValue: SensorCollectionActivityPhase.flatline.rawValue,
            phaseUntil: flatlineUntil,
            isExternalSample: false,
            latestHeartRate: activity.content.state.latestHeartRate,
            heartRateUpdatedAt: activity.content.state.heartRateUpdatedAt,
            sensorHUDUntil: activity.content.state.sensorHUDUntil,
            currentActivityTitle: activity.content.state.currentActivityTitle,
            currentActivityCategoryID: activity.content.state.currentActivityCategoryID,
            currentActivitySystemImage: activity.content.state.currentActivitySystemImage,
            daySummary: activity.content.state.daySummary
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: flatlineUntil),
            dismissalPolicy: .after(flatlineUntil)
        )
        if self.activity?.id == activity.id {
            self.activity = nil
        }
    }

    func removeExpired(now: Date = .now) async {
        await recoverAndRemoveDuplicates(sessionID: nil, now: now)
        guard let activity,
              SensorCollectionActivityPolicy.isExpired(
                startedAt: activity.content.state.startedAt,
                now: now
              ) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    func activeID() -> String? {
        activity?.id
    }

    /// 데이터 삭제 때 센서 수집 활동을 모두 바로 끝낸다(REV1110A04).
    func endAll() async {
        for candidate in Activity<SensorCollectionActivityAttributes>.activities {
            await candidate.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    private func recoverAndRemoveDuplicates(
        sessionID: UUID?,
        now: Date
    ) async {
        if let current = activity, !isLive(current) {
            activity = nil
        }
        if let current = activity {
            let isExpired = SensorCollectionActivityPolicy.isExpired(
                startedAt: current.content.state.startedAt,
                now: now
            )
            let isWrongSession = sessionID.map {
                current.attributes.sessionID != $0
            } ?? false
            if isExpired || isWrongSession {
                await current.end(nil, dismissalPolicy: .immediate)
                activity = nil
            }
        }
        var selected = activity
        for candidate in Activity<SensorCollectionActivityAttributes>.activities {
            guard isLive(candidate) else { continue }
            let expired = SensorCollectionActivityPolicy.isExpired(
                startedAt: candidate.content.state.startedAt,
                now: now
            )
            let matchesSession = sessionID == nil
                || candidate.attributes.sessionID == sessionID
            if !expired, matchesSession, selected == nil {
                selected = candidate
            } else if selected?.id != candidate.id {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = selected
    }

    private func isLive(
        _ activity: Activity<SensorCollectionActivityAttributes>
    ) -> Bool {
        switch activity.activityState {
        case .active, .pending, .stale:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }
}

actor TaptionLiveActivityController {
    private var activity: Activity<TaptionActivityAttributes>?
    private var lastCompactUpdateAt: Date?

    func concealAll() async {
        for candidate in Activity<TaptionActivityAttributes>.activities {
            await candidate.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    /// 앱이 다시 켜져 메모리 참조가 없으면 시스템 목록에서 같은 계획의 활동을 다시 잡는다(REV1110A04).
    private func adopt(planID: UUID?) -> Activity<TaptionActivityAttributes>? {
        if let activity, LiveActivityLiveness.isLive(activity.activityState),
           planID.map({ activity.attributes.planID == $0 }) ?? true {
            return activity
        }
        activity = Activity<TaptionActivityAttributes>.activities.first { candidate in
            LiveActivityLiveness.isLive(candidate.activityState)
                && (planID.map { candidate.attributes.planID == $0 } ?? candidate.content.state.isRunning)
        }
        return activity
    }

    /// 위젯·아일랜드의 종료 명령이 반영되면 그 계획의 활동을 끝낸다(REV1110A04).
    func end(planID: UUID) async {
        for candidate in Activity<TaptionActivityAttributes>.activities
        where candidate.attributes.planID == planID {
            await candidate.end(Self.endedContent(candidate), dismissalPolicy: .default)
        }
        if activity?.attributes.planID == planID { activity = nil }
    }

    static func endedContent(
        _ activity: Activity<TaptionActivityAttributes>,
        now: Date = .now
    ) -> ActivityContent<TaptionActivityAttributes.ContentState> {
        var state = activity.content.state
        state.isRunning = false
        state.endsAt = max(state.startedAt, min(now, state.endsAt))
        return ActivityContent(state: state, staleDate: nil)
    }

    func updateCompactActivity(
        title: String,
        categoryID: String,
        animationFrame: Int? = nil,
        now: Date = .now
    ) async {
        // 끝난 계획은 고르지 않고, 고양이 프레임만 바뀌면 60초에 한 번만 보낸다(REV1110A04).
        let running = { (candidate: Activity<TaptionActivityAttributes>) in
            LiveActivityLiveness.isLive(candidate.activityState)
                && candidate.content.state.isRunning
                && candidate.content.state.endsAt > now
        }
        guard let activity = activity.flatMap({ running($0) ? $0 : nil })
            ?? Activity<TaptionActivityAttributes>.activities.first(where: running) else { return }
        self.activity = activity
        var state = activity.content.state
        let contentChanged = state.compactActivityTitle != title
            || state.compactActivityCategoryID != categoryID
        let frameDue = state.compactAnimationFrame != animationFrame
            && lastCompactUpdateAt.map { now.timeIntervalSince($0) >= 60 } ?? true
        guard contentChanged || frameDue else { return }
        state.compactActivityTitle = title
        state.compactActivityCategoryID = categoryID
        state.compactAnimationFrame = animationFrame
        lastCompactUpdateAt = now
        await activity.update(ActivityContent(
            state: state,
            staleDate: activity.content.staleDate
        ))
    }

    func start(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = AppLanguagePreference.text(korean: "활동", english: "Activity"),
        majorCategorySystemImage: String = "sparkles",
        compactActivityTitle: String? = nil,
        compactActivityCategoryID: String? = nil
    ) async throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.unavailable
        }
        guard plan.span.duration <= 8 * 3_600 else {
            throw LiveActivityError.durationExceedsEightHours
        }

        // 앱 재실행 뒤 남은 활동까지 모두 끝내 하나만 남긴다(REV1110A04).
        await concealAll()

        let state = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: plan.span.end,
            catStyle: catStyle.rawValue,
            isRunning: true,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage,
            compactActivityTitle: compactActivityTitle,
            compactActivityCategoryID: compactActivityCategoryID
        )
        let newActivity = try Activity.request(
            attributes: TaptionActivityAttributes(planID: plan.id),
            content: ActivityContent(
                state: state,
                staleDate: plan.span.end
            ),
            pushType: nil
        )
        activity = newActivity
        return newActivity.id
    }

    func update(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = AppLanguagePreference.text(korean: "활동", english: "Activity"),
        majorCategorySystemImage: String = "sparkles",
        compactActivityTitle: String? = nil,
        compactActivityCategoryID: String? = nil
    ) async throws {
        guard let activity = adopt(planID: plan.id) else { throw LiveActivityError.missingActivity }
        let compactActivityTitle = compactActivityTitle
            ?? activity.content.state.compactActivityTitle
        let compactActivityCategoryID = compactActivityCategoryID
            ?? activity.content.state.compactActivityCategoryID
        let state = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: plan.span.end,
            catStyle: catStyle.rawValue,
            isRunning: plan.status == .running,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage,
            compactActivityTitle: compactActivityTitle,
            compactActivityCategoryID: compactActivityCategoryID
        )
        await activity.update(
            ActivityContent(state: state, staleDate: plan.span.end)
        )
    }

    func stop(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = AppLanguagePreference.text(korean: "활동", english: "Activity"),
        majorCategorySystemImage: String = "sparkles",
        compactActivityTitle: String? = nil,
        compactActivityCategoryID: String? = nil
    ) async throws {
        guard let activity = adopt(planID: plan.id) else { throw LiveActivityError.missingActivity }
        let compactActivityTitle = compactActivityTitle
            ?? activity.content.state.compactActivityTitle
        let compactActivityCategoryID = compactActivityCategoryID
            ?? activity.content.state.compactActivityCategoryID
        let finalState = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: max(plan.span.start, min(.now, plan.span.end)),
            catStyle: catStyle.rawValue,
            isRunning: false,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage,
            compactActivityTitle: compactActivityTitle,
            compactActivityCategoryID: compactActivityCategoryID
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .default
        )
        if self.activity?.id == activity.id { self.activity = nil }
    }

    func activeID() -> String? {
        activity?.id
    }
}

enum LiveActivityLiveness {
    static func isLive(_ state: ActivityState) -> Bool {
        switch state {
        case .active, .pending, .stale: true
        default: false
        }
    }
}

/// 잠금 화면 연봉 카운터가 읽는 기준값. 앱이 쓰고 Live Activity가 읽는 키를 여기 하나에 둔다.
struct SalaryLiveSnapshot: Equatable {
    static let textKey = "mapHomeSalaryLiveText"
    static let baseKey = "mapHomeSalaryLiveBase"
    static let rateKey = "mapHomeSalaryLiveRate"
    static let measuredAtKey = "mapHomeSalaryLiveMeasuredAt"
    static let workingKey = "mapHomeSalaryLiveWorking"
    static let tickKey = "mapHomeSalaryLiveTick"
    static let keys = [textKey, baseKey, rateKey, measuredAtKey, workingKey, tickKey]

    var text: String?
    /// 측정 시각이 없으면 나머지 수치는 없다(문자열만 보여 준다).
    var baseSeconds: Double?
    var hourlyRate: Double?
    var measuredAt: Date?
    var isWorking: Bool?
    var tickSeconds: Int?

    static func read(_ defaults: UserDefaults = .standard) -> SalaryLiveSnapshot {
        let measuredAt = defaults.object(forKey: measuredAtKey) as? Date
        let measured = measuredAt != nil
        return SalaryLiveSnapshot(
            text: defaults.string(forKey: textKey),
            baseSeconds: measured ? defaults.double(forKey: baseKey) : nil,
            hourlyRate: measured ? defaults.double(forKey: rateKey) : nil,
            measuredAt: measuredAt,
            isWorking: measured ? defaults.bool(forKey: workingKey) : nil,
            tickSeconds: measured ? defaults.integer(forKey: tickKey) : nil
        )
    }

    /// nil이면 모든 키를 지운다.
    static func write(_ value: SalaryLiveSnapshot?, to defaults: UserDefaults = .standard) {
        guard let value else {
            keys.forEach(defaults.removeObject(forKey:))
            return
        }
        defaults.set(value.text, forKey: textKey)
        defaults.set(value.baseSeconds, forKey: baseKey)
        defaults.set(value.hourlyRate, forKey: rateKey)
        defaults.set(value.measuredAt, forKey: measuredAtKey)
        defaults.set(value.isWorking, forKey: workingKey)
        defaults.set(value.tickSeconds.map { max(1, $0) }, forKey: tickKey)
    }
}
