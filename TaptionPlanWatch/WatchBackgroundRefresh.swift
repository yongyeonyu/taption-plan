import WatchConnectivity
import WatchKit

/// 앱이 꺼져 있어도 기록기 표본을 주기적으로 비워 iPhone으로 보낸다(WCH1105A01).
/// 실행 시각은 watchOS가 정하므로 요청한 간격을 보장하지 않는다.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static var onRefresh: (@Sendable @MainActor () async -> Void)?

    private static let refreshInterval: TimeInterval = 30 * 60

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
                    let deadline = ContinuousClock.now + TaptionWatchBackgroundBudget.connectivityWait
                    while WCSession.default.hasContentPending, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    connectivity.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// 백그라운드 실행 예산 안에서 돌아온다. 넘기면 동기화를 취소하고 기다리지 않는다.
    /// 커밋하지 못한 창과 ack를 못 받은 outbox는 다음 실행이 잇는다(WSY1117A01).
    private func runRefresh() async {
        guard let onRefresh = Self.onRefresh else { return }
        let finished = await TaptionWatchBackgroundBudget.run(
            within: TaptionWatchBackgroundBudget.refresh
        ) {
            await onRefresh()
        }
        if !finished {
            WatchLaunchDiagnostics.mark("background refresh budget exceeded")
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
