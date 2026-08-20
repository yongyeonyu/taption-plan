@preconcurrency import ActivityKit
import Foundation

enum LiveActivityError: Error, Equatable {
    case unavailable
    case durationExceedsEightHours
    case missingActivity
}

actor TaptionLiveActivityController {
    private var activity: Activity<TaptionActivityAttributes>?

    func start(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = "활동"
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
            majorCategoryTitle: majorCategoryTitle
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
        majorCategoryTitle: String = "활동"
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
            majorCategoryTitle: majorCategoryTitle
        )
        await activity.update(
            ActivityContent(state: state, staleDate: plan.span.end)
        )
    }

    func stop(
        plan: PlanRecord,
        catStyle: CatStyle,
        majorCategoryID: String = "activity",
        majorCategoryTitle: String = "활동"
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
            majorCategoryTitle: majorCategoryTitle
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
