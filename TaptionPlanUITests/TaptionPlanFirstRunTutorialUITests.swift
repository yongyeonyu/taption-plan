import XCTest

/// 처음 실행 튜토리얼 전 단계를 지나며 화면을 남긴다(FRT1104A01).
/// `-firstRunStore <이름>`(Debug 전용)으로 시험마다 새 "마침" 저장소를 써서, 이미 쓰던 설치에서도 첫 실행처럼 뜬다(RMN1114A25).
@MainActor
final class TaptionPlanFirstRunTutorialUITests: XCTestCase {
    private let stepCount = 21
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

    /// 건너뛰기는 다음 단계로, 이전은 앞 단계로 간다. 전체 건너뛰기는 첫 화면의 바로 시작뿐이다.
    func testSkipStepAndBack() {
        let app = launchFresh()
        element(app, "firstRunNext").tap()
        passAIConnect(app)
        assertStep(app, 3)
        element(app, "firstRunSkip").tap()
        assertStep(app, 4)
        capture("skip-step-4")
        XCTAssertFalse(element(app, "firstRunSkipAll").exists)
        element(app, "firstRunBack").tap()
        assertStep(app, 3)
    }

    /// 2단계 AI 연결(AIT1116A01): 「지금 연결」은 AI 고르기를 띄우고, 닫으면 같은 단계로 돌아온다. 「나중에」로 넘어간다.
    /// 서버를 쓸 수 없는 빌드는 「지금 연결」이 그대로 다음 단계로 넘긴다.
    private func passAIConnect(_ app: XCUIApplication, captureName: String? = nil) {
        assertStep(app, 2)
        XCTAssertTrue(element(app, "firstRunAIConnect").waitForExistence(timeout: 5))
        if let captureName { capture(captureName) }
        let later = element(app, "firstRunAILater")
        guard later.waitForExistence(timeout: 3) else {
            element(app, "firstRunNext").tap()
            return
        }
        element(app, "firstRunNext").tap()
        let chooser = element(app, "firstRunAIChooser")
        if chooser.waitForExistence(timeout: 10) {
            if let captureName { capture(captureName + "-chooser") }
            app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "완료", "Done")).firstMatch.tap()
            XCTAssertTrue(UITestWait.until(10) { !chooser.exists }, "AI 고르기를 닫지 못했다")
            assertStep(app, 2)
        }
        later.tap()
    }

    /// 왼쪽 위 「닫기」는 처음 실행 중간 단계에서도, 메뉴 > 설정 > 다시 보기에서도 튜토리얼을 닫는다(TUT1105A02).
    func testCloseButtonClosesFirstRunAndReplay() {
        let app = launchFresh()
        element(app, "firstRunNext").tap()
        assertStep(app, 2)
        capture("close-first-run-before")
        element(app, "firstRunClose").tap()
        assertTutorialStaysClosed(app)

        let replayRow = openReplayRow(app)
        replayRow.tap()
        assertStep(app, 1)
        element(app, "firstRunNext").tap()
        assertStep(app, 2)
        capture("close-replay-before")
        element(app, "firstRunClose").tap()
        XCTAssertTrue(UITestWait.until(10) { !self.element(app, "firstRunTutorial").exists }, "다시 보기 닫기가 튜토리얼을 닫지 않았다")
        XCTAssertTrue(replayRow.waitForExistence(timeout: 10))
        capture("close-replay-after")
    }

    /// 메뉴 > 설정 목록을 열어 다시 보기 줄을 보이게 한다.
    private func openReplayRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "메뉴")).firstMatch.tap()
        let settingsRow = app.buttons["설정 목록"]
        var tries = 0
        while !settingsRow.isHittable, tries < 6 { app.swipeUp(); tries += 1 }
        settingsRow.tap()
        let replayRow = element(app, "firstRunTutorialReplay")
        tries = 0
        while !replayRow.isHittable, tries < 4 { app.swipeUp(); tries += 1 }
        return replayRow
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments += ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"] + freshStoreArguments()
        XCTAssertTrue(launchUntilTutorial(app))
        return app
    }

    /// 같은 앱 인스턴스를 다시 띄우면 같은 저장소를 읽으므로 "다시 실행해도 안 뜬다"를 그대로 확인한다.
    private func freshStoreArguments() -> [String] {
        ["-firstRunStore", "uitest-\(UUID().uuidString)"]
    }

    /// 실행 묶음의 첫 시험은 설치 직후라 앱이 백그라운드로 먼저 떠서(FrontBoard `intent background`) 튜토리얼 판단을 건너뛴다.
    /// 그때는 한 번 더 앞에서 띄운다. 저장소 이름이 같아 여전히 첫 실행이다(RMN1114A25 보고의 앱 쪽 의심 항목).
    private func launchUntilTutorial(_ app: XCUIApplication) -> Bool {
        app.launchWithoutPrompts()
        if element(app, "firstRunTutorial").waitForExistence(timeout: 30) { return true }
        app.terminate()
        app.launchWithoutPrompts()
        return element(app, "firstRunTutorial").waitForExistence(timeout: 60)
    }

    private func assertTutorialStaysClosed(_ app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("closed")
        app.terminate()
        app.launchWithoutPrompts()
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
        app.launchArguments += ["-AppleLanguages", "(\(languageCode))", "-AppleLocale", locale] + freshStoreArguments()
        XCTAssertTrue(launchUntilTutorial(app), "새 설치 첫 화면은 튜토리얼이다")
        // 튜토리얼이 권한을 묻기 전에는 시스템 창이 먼저 뜨지 않는다.
        XCTAssertFalse(springboard.alerts.firstMatch.exists)

        captureAndAdvance(app, 1, "welcome")
        // AI 연결이 첫 소개 바로 다음이다(AIT1116A01). 그래서 21단계는 그대로이고 나머지가 한 칸씩 밀렸다.
        passAIConnect(app, captureName: "02-ai-connect")

        assertStep(app, 3)
        capture("03-permissions-before")
        let allow = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "허용하기", "Allow")).firstMatch
        // 허용 단추는 아직 묻지 않은 권한에만 있다. 이미 답한 기기에서는 없으므로 있을 때만 누른다.
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
            answerAlert(timeout: 10)
            answerAlert()
        }
        capture("03-permissions-after-location")
        element(app, "firstRunNext").tap()

        // 센서 주기 단계는 없앴다(VER1109A01). 하루 카드 시각부터 이어진다.
        assertStep(app, 4)
        XCTAssertTrue(element(app, "firstRunDayCardTime").waitForExistence(timeout: 5))
        captureAndAdvance(app, 4, "day-card-time")

        captureAndAdvance(app, 5, "home")
        captureAndAdvance(app, 6, "work-school")
        // 내 차(CRT1111A01)와 단축어 · Siri(SHT1111A01) 단계가 있다.
        captureAndAdvance(app, 7, "car")
        captureAndAdvance(app, 8, "salary")

        assertStep(app, 9)
        let cat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "firstRunCat.")).element(boundBy: 1)
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        cat.tap()
        captureAndAdvance(app, 9, "cat")

        for (offset, name) in ["map", "playback", "sidebar-calendar", "clip-editor", "memos", "summary", "counters"].enumerated() {
            assertStep(app, 10 + offset)
            capture(String(format: "%02d-%@-첫줄", 10 + offset, name))
            usleep(3_500_000)
            captureAndAdvance(app, 10 + offset, name)
        }

        assertStep(app, 17)
        capture("17-calendar-before")
        let calendarAllow = element(app, "firstRunCalendarAllow")
        if calendarAllow.waitForExistence(timeout: 3) {
            calendarAllow.tap()
            answerAlert(timeout: 10)
        }
        capture("17-calendar-after")
        element(app, "firstRunNext").tap()

        captureAndAdvance(app, 18, "apple-watch")
        captureAndAdvance(app, 19, "shortcuts")
        captureAndAdvance(app, 20, "password")
        captureAndAdvance(app, 21, "finish")

        // 끝나면 지도가 나오고, 메뉴 > 설정에서 다시 볼 수 있다.
        answerAlert(timeout: 3)
        let menuButton = app.buttons.matching(NSPredicate(format: "label == %@", menu)).firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("22-map-home")
        menuButton.tap()
        let settingsRow = app.buttons[settings]
        var tries = 0
        while !settingsRow.isHittable, tries < 6 { app.swipeUp(); tries += 1 }
        settingsRow.tap()
        let replayRow = element(app, "firstRunTutorialReplay")
        tries = 0
        while !replayRow.isHittable, tries < 4 { app.swipeUp(); tries += 1 }
        capture("22-menu-replay-\(replay)")
        replayRow.tap()
        assertStep(app, 1)
        capture("22-replay-welcome")
        element(app, "firstRunStartNow").tap()
        XCTAssertTrue(replayRow.waitForExistence(timeout: 10))

        // 다시 실행해도 튜토리얼이 또 뜨지 않는다.
        app.terminate()
        app.launchWithoutPrompts()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 40))
        XCTAssertFalse(element(app, "firstRunTutorial").exists)
        capture("23-relaunch")
    }
}
