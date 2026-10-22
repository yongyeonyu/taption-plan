import BackgroundTasks
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore
import UIKit
import UserNotifications
import WidgetKit

private final class TaptionBackgroundTaskBox: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var isCompleted = false

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}

@main
struct TaptionPlanApp: App {
    @UIApplicationDelegateAdaptor(TaptionPlanAppDelegate.self)
    private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 설정 파일에 저장된 값을 화면이 읽기 전에 되돌린다(앱을 업데이트해도 설정이 유지된다).
        AppSettingsFile.restore()
        TaptionPlanSharedContainer.configure(
            provider: FixedTaptionPlanAppGroupProvider(
                identifier: TaptionPlanSharedContainer.defaultAppGroupIdentifier
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
        .onChange(of: scenePhase) { _, phase in
            // 앱이 백그라운드로 가거나 꺼질 때 현재 설정을 파일에 적는다.
            if phase == .background || phase == .inactive { AppSettingsFile.save() }
        }
    }
}

/// 앱의 모든 설정(화면·알림·달력·보폭·연봉 등 사용자 설정 값)을 한 파일에 보관한다.
/// 위치는 앱 Application Support 안이라 앱을 업데이트해도 지워지지 않는다. 시스템 값과 캐시는 제외한다.
enum AppSettingsFile {
    private static let excludedPrefixes = ["Apple", "NS", "AK", "com.apple", "WebKit"]

    static var url: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TaptionPlan/Settings", isDirectory: true)
            .appendingPathComponent("app-settings.plist")
    }

    /// 파일에 있는 값을 UserDefaults에 되돌린다. 파일이 없으면 아무것도 하지 않는다.
    static func restore() {
        guard let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        for (key, value) in dictionary {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// 현재 설정을 파일로 저장한다(원자적 쓰기).
    static func save() {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let settings = all.filter { key, _ in
            !excludedPrefixes.contains { key.hasPrefix($0) }
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: settings,
            format: .xml,
            options: 0
        ) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
        request.earliestBeginDate = Date.now.addingTimeInterval(
            SensorBackgroundRefreshPolicy.savedDelay()
        )
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
            _ = SensorBackgroundCoordinator.shared.receiveWake(.bgAppRefresh)
            guard await TaptionProAccessController.currentAccessGranted() else {
                taskBox.complete(success: true)
                logger.notice("Background refresh skipped while Pro is locked")
                return
            }
            let model = AppModel.backgroundTaskInstance()
            let success = await model.performBackgroundRefresh(
                wakeReason: .bgAppRefresh
            )
            taskBox.complete(success: success)
            logger.notice(
                "Background refresh completed: success=\(success, privacy: .public)"
            )
        }
        task.expirationHandler = {
            operation.cancel()
            taskBox.complete(success: false)
            logger.error("Background refresh expired")
        }
    }
}

enum SensorBackgroundWakeNotification {
    private static let identifier =
        "com.taption.plan.sensor-background-wake"

    static func schedule(after delay: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = AppLanguagePreference.text(
            korean: "센서 기록 확인",
            english: "Sensor recording check"
        )
        content.body = AppLanguagePreference.text(
            korean: "iOS가 허용하는 다음 실행에서 센서 기록을 이어갑니다.",
            english: "Sensor recording resumes at the next opportunity allowed by iOS."
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(60, delay),
                repeats: false
            )
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
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
    private var sensorRecoveryTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let session = TaptionPlanDiagnosticsSession.begin()
        TaptionPlanSystemDiagnostics.shared.start()
        if session.previousSessionWasUnfinished == true {
            TaptionPlanDiagnosticsLogger.shared.record(
                "previous_session_unfinished",
                level: .notice,
                fields: TaptionPlanDiagnosticsSession.latestSummary()
            )
        }
        TaptionPlanDeviceLocalStorage.excludeFromBackup()
        Task.detached(priority: .utility) {
            try? TaptionPlanDiagnosticsICloudExporter()
                .removeLegacyPersonalHealthLogsIfNeeded()
        }
        UNUserNotificationCenter.current().delegate = self
        TaptionPlanBackgroundRefresh.register()
        let launchReason = launchOptions?[.location] == nil
            ? "launch"
            : "location-event"
        _ = SensorBackgroundCoordinator.shared.receiveWake(
            launchOptions?[.location] == nil
                ? .appLaunch
                : .locationRelaunch
        )
        TaptionPlanBackgroundRefresh.schedule(reason: launchReason)
        if launchOptions?[.location] != nil {
            sensorRecoveryTask = Task { @MainActor in
                guard await TaptionProAccessController.currentAccessGranted()
                else { return }
                let model = AppModel.backgroundTaskInstance()
                _ = await model.performBackgroundRefresh(
                    wakeReason: .locationRelaunch
                )
            }
        }
        AppleHealthService.shared.startObservingChanges {
            guard await TaptionProAccessController.currentAccessGranted() else {
                return
            }
            let accepted = await SensorBackgroundCoordinator.shared.receiveWake(
                .healthKitBackgroundDelivery
            )
            guard accepted else { return }
            if await HealthBackgroundRefreshCoordinator.shared
                .dispatchIfRegistered() {
                return
            }
            let model = await MainActor.run {
                AppModel.backgroundTaskInstance()
            }
            await model.performHealthBackgroundRefresh()
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TaptionPlanDiagnosticsSession.markCleanTermination()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        TaptionPlanDiagnosticsSession.recordPhase(.background)
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: false
        )
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
    }

    func applicationWillResignActive(_ application: UIApplication) {
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: false
        )
    }

    func applicationProtectedDataWillBecomeUnavailable(
        _ application: UIApplication
    ) {
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: false
        )
    }

    func applicationProtectedDataDidBecomeAvailable(
        _ application: UIApplication
    ) {
        guard application.applicationState == .active else { return }
        PhoneScreenActivityStore.update(
            brightness: Double(UIScreen.main.brightness),
            isOn: true
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
        if let kind = response.notification.request.content.userInfo[MapHomeAlarmCenter.userInfoKind] as? String {
            let at = response.notification.request.content.userInfo[MapHomeAlarmCenter.userInfoAt] as? Double ?? Date.now.timeIntervalSince1970
            NotificationCenter.default.post(
                name: .taptionPlanAlarmTapped,
                object: nil,
                userInfo: ["kind": kind, "at": at]
            )
            return
        }
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
    static let taptionPlanAlarmTapped = Notification.Name("TaptionPlanAlarmTapped")
}
