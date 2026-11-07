import XCTest

/// 고정 `sleep` 대신 화면 상태를 기다린다(REV1026A01). 시뮬레이터 부하에 따라 애니메이션이 늦게 끝나도 같은 화면을 찍는다.
enum UITestWait {
    /// 조건이 참이 될 때까지 기다린다.
    @discardableResult
    static func until(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// 새로 깐 기기에서 지도 홈까지 간다. 첫 실행은 튜토리얼 전체 화면이 지도를 덮으므로 첫 화면의 「바로 시작」으로 닫고,
    /// 옛 권한 시트(「전체 건너뛰기」)와 시스템 권한 창(거절)도 그때그때 넘긴다. 데이터는 바꾸지 않는다.
    @discardableResult
    static func reachMapHome(_ app: XCUIApplication, menu: XCUIElement, timeout: TimeInterval = 90) -> Bool {
        let startNow = app.descendants(matching: .any).matching(identifier: "firstRunStartNow").firstMatch
        let closeTutorial = app.descendants(matching: .any).matching(identifier: "firstRunClose").firstMatch
        let skipAll = app.buttons["전체 건너뛰기"]
        return until(timeout) {
            if menu.exists, menu.isHittable { return true }
            if declineSystemAlert() { return false }
            if startNow.exists, startNow.isHittable {
                startNow.tap()
            } else if closeTutorial.exists, closeTutorial.isHittable {
                closeTutorial.tap()
            } else if skipAll.exists, skipAll.isHittable {
                skipAll.tap()
            }
            return false
        }
    }

    /// 떠 있는 시스템 권한 창을 거절한다. 거절했으면 true.
    @discardableResult
    static func declineSystemAlert() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists,
              let label = ["허용 안 함", "Don’t Allow", "Don't Allow"].first(where: { alert.buttons[$0].exists })
        else { return false }
        alert.buttons[label].tap()
        return true
    }

    /// 화면 요소 수와 창 안 첫 버튼들 자리가 두 번 연속 같으면 움직임이 끝난 것으로 본다.
    /// 시계처럼 글자만 바뀌는 요소는 수와 자리를 바꾸지 않으므로 기다림이 끝난다.
    static func settled(_ app: XCUIApplication, timeout: TimeInterval = 4) {
        // 설정 앱으로 넘어간 동안에는 앱 트리를 읽을 수 없다.
        guard app.state == .runningForeground else { return }
        func shape() -> String {
            let buttons = app.buttons.allElementsBoundByIndex.prefix(12).map { "\($0.frame.integral)" }
            return "\(app.descendants(matching: .any).count)|" + buttons.joined(separator: ",")
        }
        var last = ""
        until(timeout) {
            guard app.state == .runningForeground else { return true }
            let now = shape()
            defer { last = now }
            return now == last
        }
    }
}
