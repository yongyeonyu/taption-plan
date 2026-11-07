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

    /// 화면 요소 수와 창 안 첫 버튼들 자리가 두 번 연속 같으면 움직임이 끝난 것으로 본다.
    /// 시계처럼 글자만 바뀌는 요소는 수와 자리를 바꾸지 않으므로 기다림이 끝난다.
    static func settled(_ app: XCUIApplication, timeout: TimeInterval = 4) {
        func shape() -> String {
            let buttons = app.buttons.allElementsBoundByIndex.prefix(12).map { "\($0.frame.integral)" }
            return "\(app.descendants(matching: .any).count)|" + buttons.joined(separator: ",")
        }
        var last = ""
        until(timeout) {
            let now = shape()
            defer { last = now }
            return now == last
        }
    }
}
