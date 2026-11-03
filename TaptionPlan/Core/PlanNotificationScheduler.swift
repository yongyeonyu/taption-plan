import Foundation
import UserNotifications
import TaptionPlanCore

actor PlanNotificationScheduler {
    static let identifierPrefix = "plan-start-"

    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> PermissionState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestPermission() async throws -> PermissionState {
        _ = try await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        return await authorizationState()
    }

    func scheduleStartReminder(for plan: PlanRecord) async throws {
        guard plan.span.start > .now, plan.status == .planned else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = AppLanguagePreference.text(
            korean: "계획 시작 시간입니다.",
            english: "It's time for your plan to start."
        )
        content.sound = .default
        content.userInfo = ["planID": plan.id.uuidString]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: plan.span.start
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: Self.identifier(for: plan.id),
                content: content,
                trigger: trigger
            )
        )
    }

    func synchronize(
        plans: [PlanRecord],
        now: Date = .now
    ) async throws {
        guard await authorizationState().isGranted else { return }

        let desired = PlanNotificationPolicy.reminderPlans(
            from: plans,
            now: now
        )
        let desiredIDs = Set(desired.map { Self.identifier(for: $0.id) })
        let current = await center.pendingNotificationRequests()
        let managed = current.filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
        }
        let obsolete = managed
            .map(\.identifier)
            .filter { !desiredIDs.contains($0) }
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: obsolete
            )
        }

        let existingByID = Dictionary(
            uniqueKeysWithValues: managed.map { ($0.identifier, $0) }
        )
        for plan in desired {
            let identifier = Self.identifier(for: plan.id)
            let existingDate = (
                existingByID[identifier]?.trigger
                    as? UNCalendarNotificationTrigger
            )?.nextTriggerDate()
            if let existingDate,
               abs(existingDate.timeIntervalSince(plan.span.start)) < 1 {
                continue
            }
            if existingByID[identifier] != nil {
                center.removePendingNotificationRequests(
                    withIdentifiers: [identifier]
                )
            }
            try await scheduleStartReminder(for: plan)
        }
    }

    func cancel(for planID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: planID)]
        )
    }

    func cancelAllPlanReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated static func identifier(for planID: UUID) -> String {
        "\(identifierPrefix)\(planID.uuidString)"
    }
}

enum PlanNotificationPolicy {
    /// 근처 메모 알림(`NearbyMemoPolicy.maximumPlaces`)과 예약 알림 자리를 나눠 쓴다.
    static let maximumPendingPlanReminders = 50

    static func reminderPlans(
        from plans: [PlanRecord],
        now: Date,
        limit: Int = maximumPendingPlanReminders
    ) -> [PlanRecord] {
        plans
            .filter {
                $0.status == .planned
                    && $0.span.start > now
            }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
