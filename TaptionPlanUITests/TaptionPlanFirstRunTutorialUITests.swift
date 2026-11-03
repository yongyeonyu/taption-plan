import XCTest

/// 지운 시뮬레이터에서 처음 실행 튜토리얼 전 단계를 지나며 화면을 남긴다(FRT1104A01). 설치 상태에 달려 있어 앱을 지운 뒤 하나씩 실행한다.
@MainActor
final class TaptionPlanFirstRunTutorialUITests: XCTestCase {
    private let stepCount = 16
    private let allowLabels = ["앱을 사용하는 동안 허용", "Allow While Using App", "전체 접근 허용", "Allow Full Access", "허용", "Allow"]
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testKoreanWalkthrough() { walkThrough(languageCode: "ko", locale: "ko_KR", replay: "튜토리얼 다시 보기", menu: "메뉴", settings: "설정 목록") }
    func testEnglishWalkthrough() { walkThrough(languageCode: "en", locale: "en_US", replay: "Replay tutorial", menu: "Menu", settings: "Settings list") }

    /// 첫 화면의 "바로 시작"은 튜토리얼을 닫고, 다시 실행해도 뜨지 않는다.
    func testStartNow() {
        let app = launchFresh()
        element(app, "firstRunStartNow").tap()
        assertTutorialStaysClosed(app)
    }

    /// 단계 건너뛰기는 다음 단계로 가고, 전체 건너뛰기는 튜토리얼을 닫는다.
    func testSkipStepThenSkipAll() {
        let app = launchFresh()
        element(app, "firstRunNext").tap()
        assertStep(app, 2)
        element(app, "firstRunSkip").tap()
        assertStep(app, 3)
        capture("skip-step-3")
        element(app, "firstRunSkipAll").tap()
        assertTutorialStaysClosed(app)
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments += ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        XCTAssertTrue(element(app, "firstRunTutorial").waitForExistence(timeout: 60))
        return app
    }

    private func assertTutorialStaysClosed(_ app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("closed")
        app.terminate()
        app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("relaunch")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func answerAlert(timeout: TimeInterval = 4) {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        capture("alert-\(alert.label)")
        for label in allowLabels where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func assertStep(_ app: XCUIApplication, _ number: Int, line: UInt = #line) {
        let label = "\(number) / \(stepCount)"
        let expectation = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element(app, "firstRunProgress"))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "단계 \(label)", line: line)
    }

    /// 화면과, 아래로 밀었을 때의 나머지를 남기고 다음으로 간다.
    private func captureAndAdvance(_ app: XCUIApplication, _ number: Int, _ name: String) {
        assertStep(app, number)
        capture(String(format: "%02d-%@", number, name))
        let page = element(app, "firstRunTutorial").scrollViews.firstMatch
        if page.exists {
            page.swipeUp()
            capture(String(format: "%02d-%@-아래", number, name))
        }
        element(app, "firstRunNext").tap()
    }

    private func walkThrough(languageCode: String, locale: String, replay: String, menu: String, settings: String) {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments += ["-AppleLanguages", "(\(languageCode))", "-AppleLocale", locale]
        app.launch()
        XCTAssertTrue(element(app, "firstRunTutorial").waitForExistence(timeout: 60), "새 설치 첫 화면은 튜토리얼이다")
        // 튜토리얼이 권한을 묻기 전에는 시스템 창이 먼저 뜨지 않는다.
        XCTAssertFalse(springboard.alerts.firstMatch.exists)

        captureAndAdvance(app, 1, "welcome")

        assertStep(app, 2)
        capture("02-permissions-before")
        let allow = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "허용하기", "Allow")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        answerAlert(timeout: 10)
        answerAlert()
        capture("02-permissions-after-location")
        element(app, "firstRunNext").tap()

        captureAndAdvance(app, 3, "home")
        captureAndAdvance(app, 4, "work-school")
        captureAndAdvance(app, 5, "salary")

        assertStep(app, 6)
        let cat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "firstRunCat.")).element(boundBy: 1)
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        cat.tap()
        captureAndAdvance(app, 6, "cat")

        for (offset, name) in ["map", "playback", "sidebar-calendar", "clip-editor", "memos", "summary", "counters"].enumerated() {
            captureAndAdvance(app, 7 + offset, name)
        }

        assertStep(app, 14)
        capture("14-calendar-before")
        element(app, "firstRunCalendarAllow").tap()
        answerAlert(timeout: 10)
        capture("14-calendar-after")
        element(app, "firstRunNext").tap()

        captureAndAdvance(app, 15, "password")
        captureAndAdvance(app, 16, "finish")

        // 끝나면 지도가 나오고, 메뉴 > 설정에서 다시 볼 수 있다.
        answerAlert(timeout: 3)
        let menuButton = app.buttons.matching(NSPredicate(format: "label == %@", menu)).firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("17-map-home")
        menuButton.tap()
        let settingsRow = app.buttons[settings]
        var tries = 0
        while !settingsRow.isHittable, tries < 6 { app.swipeUp(); tries += 1 }
        settingsRow.tap()
        let replayRow = element(app, "firstRunTutorialReplay")
        tries = 0
        while !replayRow.isHittable, tries < 4 { app.swipeUp(); tries += 1 }
        capture("18-menu-replay-\(replay)")
        replayRow.tap()
        assertStep(app, 1)
        capture("19-replay-welcome")
        element(app, "firstRunSkipAll").tap()
        XCTAssertTrue(replayRow.waitForExistence(timeout: 10))

        // 다시 실행해도 튜토리얼이 또 뜨지 않는다.
        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("20-relaunch")
    }
}
