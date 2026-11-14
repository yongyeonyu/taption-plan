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
        // 벡터 지도 오프라인 저장본을 MapLibre 요청보다 먼저 읽게 한다(MAP1108A02).
        OfflineVectorMap.install()
        #if DEBUG || BENCH
        BenchSeed.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-nlePreview") {
                NLEClipEditorPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("-pinPreview") {
                MapHomePinPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("-photoBrowserPreview") {
                MapHomePhotoBrowserPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("-photoStripPreview") {
                MapHomePhotoStripPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("-passportPreview") {
                if ProcessInfo.processInfo.arguments.contains("-passportBook") {
                    MapHomePassportTapPreviewHost()
                } else {
                    MapHomePassportPreviewHost()
                }
            } else if ProcessInfo.processInfo.arguments.contains("-stampPreview") {
                MapHomeStampPreviewHost()
            } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-paymentAlertPreview") {
                let arguments = ProcessInfo.processInfo.arguments
                TaptionFontRoot { PaymentAlertPreviewHost(showsInbox: arguments.dropFirst(index + 1).first == "inbox") }
            } else if ProcessInfo.processInfo.arguments.contains("-inkPreview") {
                MapHomeInkPreviewHost()
            } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-tutorialPreview") {
                // 튜토리얼 모양 확인용(FRD1111A01, Debug 전용). 다음 인자가 단계 이름(없으면 첫 화면).
                let arguments = ProcessInfo.processInfo.arguments
                let step = arguments.indices.contains(index + 1) ? FirstRunTutorialStep(rawValue: arguments[index + 1]) : nil
                TaptionFontRoot { FirstRunTutorialView(model: AppModel(), mode: .replay, startStep: step ?? .welcome) {} }
            } else if ProcessInfo.processInfo.arguments.contains("-planRealityPreview") {
                TaptionFontRoot { PlanRealityPreviewHost() }
            } else if ProcessInfo.processInfo.arguments.contains("-aiConnectPreview") {
                // AI 연결 화면 모양 확인용(AIS1111A01, Debug 전용).
                TaptionFontRoot {
                    AssistantSettingsView(model: AppModel(), language: .korean)
                        .font(.taption(size: 17))
                }
            } else {
                TaptionFontRoot { AppShellView() }
                    .refreshesSupportedOrientations()
            }
            #else
            // 글꼴을 고르면 모든 화면이 바로 따르게 Release에도 글꼴 뿌리를 둔다(FNT1111A01: 글꼴 선택을 더할 때 Debug에만 들어갔다).
            TaptionFontRoot { AppShellView() }
                .refreshesSupportedOrientations()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // 앱이 백그라운드로 가거나 꺼질 때 현재 설정을 파일에 적는다.
            if phase == .background || phase == .inactive { AppSettingsFile.save() }
        }
    }
}

/// 앱의 모든 설정(화면·알림·달력·보폭·연봉 등 사용자 설정 값)을 한 파일에 보관한다.
/// 위치는 앱 Application Support 안이라 앱을 업데이트해도 지워지지 않는다. 시스템 값과 캐시는 제외한다.
@MainActor
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
    /// 화면이 읽기 전에 끝나야 해서 동기로 읽되, 값이 같은 키는 쓰지 않는다(키마다 cfprefsd로 쓰기가 나갔다).
    /// 옛 XML 파일도 그대로 읽힌다.
    @discardableResult
    static func restore(from file: URL = url, to defaults: UserDefaults = .standard) -> Int {
        guard let data = try? Data(contentsOf: file),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return 0 }
        lastSavedSettings = dictionary as NSDictionary
        var written = 0
        for (key, value) in dictionary where !isSame(defaults.object(forKey: key), value) {
            defaults.set(value, forKey: key)
            written += 1
        }
        return written
    }

    /// 현재 설정을 파일로 저장한다(원자적 쓰기). 내용이 같으면 쓰지 않는다. 비활성화할 때마다 불린다.
    @discardableResult
    static func save(to file: URL = url, from defaults: UserDefaults = .standard) -> Bool {
        let all = defaults.dictionaryRepresentation()
        let settings = all.filter { key, _ in
            !excludedPrefixes.contains { key.hasPrefix($0) }
        }
        guard lastSavedSettings?.isEqual(to: settings) != true
                || !FileManager.default.fileExists(atPath: file.path),
              let data = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
        else { return false }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
        lastSavedSettings = settings as NSDictionary
        return true
    }

    private static var lastSavedSettings: NSDictionary?

    private static func isSame(_ current: Any?, _ next: Any) -> Bool {
        guard let current = current as? NSObject, let next = next as? NSObject else { return false }
        return current.isEqual(next)
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
            // 앱을 열지 않아도 AI 비서 명령을 반영하고 바뀐 날을 올린다(AIR1110A02).
            await AssistantCommandRunner.runInBackground(model: model)
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

/// 예전 빌드가 예약한 "센서 기록 확인" 알림을 지운다. 센서 수신은 알리지 않는다(NTF1107A01).
enum SensorBackgroundWakeNotification {
    private static let identifier =
        "com.taption.plan.sensor-background-wake"

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
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
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationPolicy.mask(screenSize: window?.windowScene?.screen.bounds.size ?? .zero)
    }

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
                // 위치 이벤트로 다시 켜졌을 때도 AI 명령을 반영하고 바뀐 날을 올린다(AIC1112A01).
                await AssistantCommandRunner.runInBackground(model: model)
            }
        }
        ReceiptPhotoWatcher.shared.startIfNeeded()
        // AI 연결이 있을 때만 푸시 토큰을 청한다(PSH1114A06).
        Task { @MainActor in await AssistantPush.syncRegistration() }
        // 지난번에 받아 둔 규칙을 바로 쓴다. 서버와 맞추는 것은 명령 확인 때 한다(AIX1114A01 P3).
        AssistantRuleStore.refreshSnapshot()
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

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AssistantPush.registered(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "assistant_push_register_failed", level: .notice, fields: ["error": String(describing: type(of: error)), "code": String((error as NSError).code)]
        )
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AssistantPush.receive(userInfo)
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
        if let model = AppModel.applicationInstance {
            Task { @MainActor in await model.retryDeferredHealthRefreshIfNeeded() }
        }
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
        // 앱이 앞에 있으면 푸시의 일반 문구는 띄우지 않는다. 받은 내용은 앱이 직접 보인다(PSH1114A06).
        if notification.request.trigger is UNPushNotificationTrigger, AssistantPush.kind(from: notification.request.content.userInfo) != nil { return [] }
        MapHomeAlarmDiagnostics.log(MapHomeAlarmDiagnostics.presented(
            kind: notification.request.content.userInfo[MapHomeAlarmCenter.userInfoKind] as? String
        ))
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let raw = response.notification.request.content.userInfo[ArrivalCardManager.userInfoStopID] as? String,
           let stopID = UUID(uuidString: raw) {
            await ArrivalCardManager.shared.open(stopID: stopID)
            return
        }
        if let kind = response.notification.request.content.userInfo[MapHomeAlarmCenter.userInfoKind] as? String {
            MapHomeAlarmDiagnostics.log(MapHomeAlarmDiagnostics.tapped(
                kind: kind,
                actionIdentifier: response.actionIdentifier,
                deliveredAt: response.notification.date,
                now: .now
            ))
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

#if DEBUG || BENCH
/// 측정용: `-seedRawExport=<경로>`로 켜면 어제·오늘 원본 센서 기록(`Taption-Raw-2Days-*.json`)을 이 기기 저장소에 넣는다.
/// 넣은 뒤 앱을 다시 켜면 평소 경로로 분류·경로·재생이 돌아, 다른 기기에서 같은 데이터로 성능과 판정을 잴 수 있다.
/// `OTHER_SWIFT_FLAGS=-D BENCH`로 만든 측정 빌드와 Debug에만 들어가고 배포 빌드에는 없다(ARC1030A04).
enum BenchSeed {
    static func runIfRequested() {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-seedRawExport=") }) else { return }
        let path = String(argument.dropFirst("-seedRawExport=".count))
        Task.detached(priority: .utility) {
            do {
                let url = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : FileManager.default.temporaryDirectory.appendingPathComponent(path)
                let days = try JSONDecoder().decode([TodaySensorRawExport].self, from: Data(contentsOf: url))
                let readings = days.flatMap(\.readings)
                try await SensorReadingArchive.applicationSupport().append(readings)
                TaptionPlanDiagnosticsLogger.shared.record("bench_seed_done", metrics: ["readings": Double(readings.count)])
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record("bench_seed_failed", fields: ["error": String(describing: error)])
            }
        }
    }
}
#endif
