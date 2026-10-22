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
        let sensors = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "GPS 및 센서 데이터")).firstMatch
        if sensors.waitForExistence(timeout: 5) { sensors.tap() }
        let upload = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "로그 보내기", "로그 업로드")).firstMatch
        var tries = 0
        while !upload.exists && tries < 10 {
            app.swipeUp()
            tries += 1
        }
        if !upload.waitForExistence(timeout: 5) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "no-upload-button"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("로그 업로드 버튼을 찾지 못함")
            return
        }
        upload.tap()
        sleep(30)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "after-log-upload"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 알림 설정을 열고 토글을 한 번 눌러 본다(재현용). 데이터는 바꾸지 않는다.
    func testOpenAlarmSettingsAndToggle() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let menu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let alerts = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "알림")).firstMatch
        var tries = 0
        while !alerts.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(alerts.waitForExistence(timeout: 5))
        alerts.tap()
        sleep(3)
        let toggle = app.switches.firstMatch
        if toggle.waitForExistence(timeout: 5) { toggle.tap() }
        sleep(3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "alarm-after-toggle"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 하루 카드를 열고 잠시 둔다(재현용). 저장·공유는 누르지 않는다.
    func testOpenDayCard() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let menu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "하루 카드")).firstMatch
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        sleep(15)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "day-card"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 하루 카드의 사진 저장과 공유를 차례로 누른다(재현용).
    func testDayCardSaveAndShare() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let menu = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "하루 카드")).firstMatch
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        sleep(12)
        let save = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "사진에 저장")).firstMatch
        if save.waitForExistence(timeout: 5) { save.tap() }
        sleep(4)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "허용", "Allow")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(3)
        let share = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "공유")).firstMatch
        if share.waitForExistence(timeout: 5) { share.tap() }
        sleep(6)
    }

    /// 메모 추가 화면에서 음성 입력 버튼을 누른다(마이크 충돌 재현). 권한 창은 허용한다.
    func testMemoMicButtonRepro() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let add = app.buttons.containing(NSPredicate(format: "label == %@ OR label == %@", "메모", "Memo")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        let mic = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "음성으로 입력")).firstMatch
        if mic.waitForExistence(timeout: 8) { mic.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@", "허용", "확인", "OK")).firstMatch
            if allow.waitForExistence(timeout: 4) { allow.tap() }
        }
        sleep(5)
    }
}
