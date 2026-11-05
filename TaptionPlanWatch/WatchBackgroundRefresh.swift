import WatchConnectivity
import WatchKit

/// 앱이 꺼져 있어도 기록기 표본을 주기적으로 비워 iPhone으로 보낸다(WCH1105A01).
/// 실행 시각은 watchOS가 정하므로 요청한 간격을 보장하지 않는다.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static var onRefresh: (@Sendable @MainActor () async -> Void)?

    private static let refreshInterval: TimeInterval = 30 * 60
    /// 백그라운드 실행 예산 안에서 끝낸다. 전송 확인이 못 오면 다음 실행 때 다시 보낸다.
    private static let refreshBudget: Duration = .seconds(25)
    private static let connectivityWaitLimit = 20

    func applicationDidFinishLaunching() {
        scheduleRefresh()
    }

    func applicationDidEnterBackground() {
        scheduleRefresh()
    }

    func applicationDidBecomeActive() {
        WatchAppVersionReporter.report()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    WatchLaunchDiagnostics.mark("background refresh begin")
                    await runRefresh()
                    WatchAppVersionReporter.report()
                    WatchLaunchDiagnostics.mark("background refresh end")
                    scheduleRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                Task { @MainActor in
                    // 전달할 내용이 남아 있는 동안 끝내면 수신이 다음 실행으로 밀린다.
                    var waited = 0
                    while WCSession.default.hasContentPending, waited < Self.connectivityWaitLimit {
                        try? await Task.sleep(for: .seconds(1))
                        waited += 1
                    }
                    connectivity.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func runRefresh() async {
        guard let onRefresh = Self.onRefresh else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await onRefresh() }
            group.addTask { try? await Task.sleep(for: Self.refreshBudget) }
            await group.next()
            group.cancelAll()
        }
    }

    private func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.refreshInterval),
            userInfo: nil
        ) { error in
            if let error {
                WatchLaunchDiagnostics.mark("background refresh schedule failed \(error.localizedDescription)")
            }
        }
    }
}

/// iPhone 메뉴가 설치된 버전을 보여 주도록 알린다. 값이 같으면 시스템이 다시 보내지 않는다.
enum WatchAppVersionReporter {
    static func report() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let info = Bundle.main.infoDictionary
        let version = TaptionWatchAppVersion(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
        try? WCSession.default.updateApplicationContext(version.context)
    }
}
