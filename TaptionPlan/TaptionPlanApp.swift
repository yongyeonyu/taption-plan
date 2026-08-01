import SwiftUI
import UIKit
import UserNotifications

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
        AppleHealthService.shared.startObservingChanges {
            await HealthBackgroundRefreshCoordinator.shared.receiveUpdate()
        }
        return true
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
