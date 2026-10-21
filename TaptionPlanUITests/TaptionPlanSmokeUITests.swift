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

        // 권한 요청은 시스템(SpringBoard) 알림이라 앱 트리가 아니라 거기서 찾는다.
        // '허용 안 함'만 누르며 데이터 변경이 아니다.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons["허용 안 함"]
        if decline.waitForExistence(timeout: 3) {
            decline.tap()
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "home-after-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 하단 '달력'을 열어 화면을 남긴다(데이터는 바꾸지 않는다). 달력 숫자가 0으로 나오는지 눈으로 보기 위함.
    func testOpenCalendarAndCaptureForDiagnosis() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let calendar = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "달력")).firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))
        calendar.tap()
        sleep(40)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "calendar-open"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 메뉴의 '로그 업로드'를 눌러 진단 로그를 iCloud Drive에 내보낸다(데이터는 바꾸지 않는다).
    func testUploadDiagnosticsLogs() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let menu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let settings = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "설정")).firstMatch
        if settings.waitForExistence(timeout: 5) { settings.tap() }
        let upload = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "로그 업로드")).firstMatch
        var tries = 0
        while !upload.exists && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        upload.tap()
        sleep(30)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "after-log-upload"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
