@preconcurrency import ActivityKit
import Foundation

enum LiveActivityError: Error, Equatable {
    case unavailable
    case durationExceedsEightHours
    case missingActivity
}

enum SensorCollectionLiveActivityError: Error, Equatable {
    case unavailable
}

actor SensorCollectionLiveActivityController {
    static let shared = SensorCollectionLiveActivityController()

    private var activity: Activity<SensorCollectionActivityAttributes>?
    private var lastPublishedAt: Date?

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
            phaseUntil = SensorCollectionActivityPolicy.pulseUntil(now: now)
        } else if phase == .pulse {
            phaseUntil = previousState?.phaseUntil
        } else {
            phaseUntil = nil
        }
        let state = SensorCollectionActivityAttributes.ContentState(
            startedAt: activityStartedAt,
            lastSavedAt: lastSavedAt,
            collectionKinds: collectionKinds,
            isCollecting: true,
            intervalSeconds: intervalSeconds,
            sessionStateRawValue: SensorCollectionSessionState.collecting.rawValue,
            saveToken: effectiveSaveToken,
            phaseRawValue: phase.rawValue,
            phaseUntil: phaseUntil
        )
        let staleDate = SensorCollectionActivityPolicy.expirationDate(
            startedAt: activityStartedAt
        )

        if let activity {
            let shouldPublish = hasNewSample
                || state != activity.content.state
                || SensorCollectionActivityPolicy.shouldPublish(
                    lastPublishedAt: lastPublishedAt,
                    now: now
                )
            guard shouldPublish else { return activity.id }
            await activity.update(
                ActivityContent(state: state, staleDate: staleDate)
            )
            lastPublishedAt = now
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
        lastPublishedAt = now
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
            phaseUntil: flatlineUntil
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: flatlineUntil),
            dismissalPolicy: .after(flatlineUntil)
        )
        self.activity = nil
        lastPublishedAt = nil
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
        lastPublishedAt = nil
    }

    func activeID() -> String? {
        activity?.id
    }

    private func recoverAndRemoveDuplicates(
        sessionID: UUID?,
        now: Date
    ) async {
        if let current = activity, !isLive(current) {
            activity = nil
            lastPublishedAt = nil
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
                lastPublishedAt = nil
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

    func concealAll() async {
        for candidate in Activity<TaptionActivityAttributes>.activities {
            await candidate.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    func start(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = "활동",
        majorCategorySystemImage: String = "sparkles"
    ) async throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.unavailable
        }
        guard plan.span.duration <= 8 * 3_600 else {
            throw LiveActivityError.durationExceedsEightHours
        }

        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let state = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: plan.span.end,
            catStyle: catStyle.rawValue,
            isRunning: true,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage
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
        majorCategoryTitle: String = "활동",
        majorCategorySystemImage: String = "sparkles"
    ) async throws {
        guard let activity else { throw LiveActivityError.missingActivity }
        let state = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: plan.span.end,
            catStyle: catStyle.rawValue,
            isRunning: plan.status == .running,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage
        )
        await activity.update(
            ActivityContent(state: state, staleDate: plan.span.end)
        )
    }

    func stop(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = "활동",
        majorCategorySystemImage: String = "sparkles"
    ) async throws {
        guard let activity else { throw LiveActivityError.missingActivity }
        let finalState = TaptionActivityAttributes.ContentState(
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: plan.span.start,
            endsAt: min(.now, plan.span.end),
            catStyle: catStyle.rawValue,
            isRunning: false,
            majorCategoryID: majorCategoryID,
            majorCategoryTitle: majorCategoryTitle,
            majorCategorySystemImage: majorCategorySystemImage
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .default
        )
        self.activity = nil
    }

    func activeID() -> String? {
        activity?.id
    }
}

actor WidgetActionService {
    private let repository: any PlanDataRepository

    init(repository: any PlanDataRepository) {
        self.repository = repository
    }

    @discardableResult
    func perform(
        _ action: WidgetAction,
        planID: UUID,
        at date: Date = .now
    ) async throws -> TaptionDataSnapshot {
        var snapshot = try await repository.load()
        guard let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            throw PlanningError.missingPlan(planID)
        }
        let plan = snapshot.plans[planIndex]

        switch action {
        case .complete, .stopCurrentActivity:
            let result = QuickActionEngine.complete(
                plan: plan,
                actuals: snapshot.actuals,
                at: date,
                copyPlannedDurationWhenMissing: false
            )
            snapshot.plans[planIndex] = result.plan
            snapshot.actuals = result.actuals
        case .postponeThirtyMinutes:
            snapshot.plans[planIndex] = try QuickActionEngine.postpone(plan: plan)
        case .moveToNextFreeTime:
            let occupied = snapshot.plans
                .filter { $0.id != planID && $0.status != .skipped }
                .map(\.span)
                + snapshot.calendarEvents.map(\.span)
            snapshot.plans[planIndex] = try QuickActionEngine.moveToNextFreeTime(
                plan: plan,
                occupied: occupied,
                after: date
            )
        }

        snapshot.updatedAt = date
        try await repository.save(snapshot)
        return snapshot
    }
}
