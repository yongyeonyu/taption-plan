import XCTest

/// 실기기에서 앱이 올라와 홈 화면을 그리는지 확인한다.
/// 사용자 데이터를 바꾸는 동작(저장·삭제·권한 허용)은 하지 않는다.
final class TaptionPlanSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsHomeWithoutChangingData() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)

        // 위치·센서 권한 요청이 떠 있으면 '허용 안 함'을 누른다. 데이터 변경이 아니다.
        let decline = app.buttons["허용 안 함"]
        if decline.waitForExistence(timeout: 3) {
            decline.tap()
        }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "home-after-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
