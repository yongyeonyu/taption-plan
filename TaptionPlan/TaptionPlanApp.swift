import BackgroundTasks
import OSLog
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

private final class TaptionBackgroundTaskBox: @unchecked Sendable {
    private let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@main
struct TaptionPlanApp: App {
    @UIApplicationDelegateAdaptor(TaptionPlanAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
    }
}

enum TaptionPlanBackgroundRefresh {
    static let taskIdentifier = "com.taption.plan.widget-refresh"

    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "BackgroundSync"
    )

    static func register() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task)
        }
        logger.notice(
            "Background refresh registration: \(registered, privacy: .public)"
        )
    }

    static func schedule(reason: String) {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: taskIdentifier
        )
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.notice(
                "Background refresh scheduled: reason=\(reason, privacy: .public), earliest=\(request.earliestBeginDate?.timeIntervalSince1970 ?? 0, privacy: .public)"
            )
        } catch {
            logger.error(
                "Background refresh schedule failed: reason=\(reason, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func handle(_ task: BGTask) {
        schedule(reason: "task-start")
        let taskBox = TaptionBackgroundTaskBox(task)
        let operation = Task { @MainActor in
            let model = AppModel()
            let success = await model.performBackgroundRefresh()
            taskBox.complete(success: success)
            logger.notice(
                "Background refresh completed: success=\(success, privacy: .public)"
            )
        }
        task.expirationHandler = {
            operation.cancel()
            logger.error("Background refresh expired")
        }
    }
}

@MainActor
final class TaptionPlanAppDelegate:
    NSObject,
    UIApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    private static let pendingPlanKey =
        "TaptionPlan.pendingNotificationPlanID"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        TaptionAdvertisingCoordinator.shared.start()
        TaptionPlanBackgroundRefresh.register()
        let launchReason = launchOptions?[.location] == nil
            ? "launch"
            : "location-event"
        TaptionPlanBackgroundRefresh.schedule(reason: launchReason)
        AppleHealthService.shared.startObservingChanges {
            await HealthBackgroundRefreshCoordinator.shared.receiveUpdate()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        TaptionPlanBackgroundRefresh.schedule(reason: "application-background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        TaptionPlanBackgroundRefresh.schedule(reason: "application-foreground")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: true
        )
        TaptionAdvertisingCoordinator.shared.requestStartupPresentation()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: false
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let rawID = response.notification.request.content
            .userInfo["planID"] as? String,
              let planID = UUID(uuidString: rawID) else {
            return
        }
        UserDefaults.standard.set(
            rawID,
            forKey: Self.pendingPlanKey
        )
        NotificationCenter.default.post(
            name: .taptionPlanOpenNotificationPlan,
            object: planID
        )
    }

    static func takePendingPlanID() -> UUID? {
        guard let rawID = UserDefaults.standard.string(
            forKey: pendingPlanKey
        ) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingPlanKey)
        return UUID(uuidString: rawID)
    }
}

extension Notification.Name {
    static let taptionPlanOpenNotificationPlan = Notification.Name(
        "TaptionPlanOpenNotificationPlan"
    )
}
