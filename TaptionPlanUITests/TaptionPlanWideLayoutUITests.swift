import XCTest

/// 넓은 화면 배치와 방향 규칙을 실제 화면에서 잠근다. 폭으로 기대값을 가르므로 어느 기기에서든 돈다.
/// `TEST_RUNNER_WIDE_CAPTURE_DIR`을 주면 화면을 그 폴더에 남긴다.
final class TaptionPlanWideLayoutUITests: XCTestCase {
    private let wideWidth: CGFloat = 600

    private func launchHome() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments += ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-slowDayPlayback"]
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 20) { skip.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons["허용 안 함"]
        if decline.waitForExistence(timeout: 3) { decline.tap() }
        XCTAssertTrue(menuButton(app).waitForExistence(timeout: 40))
        // 런치 오버레이가 걷힌 뒤에야 탭이 닿는다.
        XCTAssertTrue(waitUntil(60) { self.menuButton(app).isHittable }, "지도 홈이 눌리지 않음")
        return app
    }

    /// 회전 애니메이션은 시뮬레이터 부하에 따라 늦게 끝난다. 고정 대기 대신 조건을 기다린다.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
        _ = waitUntil(20) {
            let window = app.windows.firstMatch.frame
            guard orientation.isLandscape == (window.width > window.height) else { return false }
            return badge.exists && badge.frame.minX > window.width * 0.6
        }
        Thread.sleep(forTimeInterval: 1)
    }

    private func menuButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "메뉴")).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["WIDE_CAPTURE_DIR"] else { return }
        let size = app.windows.firstMatch.frame.size
        let file = "\(dir)/\(Int(size.width))x\(Int(size.height))-\(name).png"
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: file))
    }

    private func assertHomeLayout(_ app: XCUIApplication, _ label: String) {
        let window = app.windows.firstMatch.frame
        let menu = menuButton(app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), label)
        let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), label)
        // 상단 메뉴(날짜 배지)는 어느 폭에서든 오른쪽 위에 있다.
        XCTAssertGreaterThan(badge.frame.minX, window.width * 0.6, label)
        XCTAssertLessThan(badge.frame.minY, 90, label)
        if window.width >= wideWidth {
            // 메인 메뉴는 왼쪽 아래에 붙고, 마지막 단추(메모)까지 폭이 늘어나지 않는다.
            XCTAssertLessThan(menu.frame.minX, 40, label)
            XCTAssertGreaterThan(menu.frame.maxY, window.height - 110, label)
            let memo = app.buttons.matching(NSPredicate(format: "label == %@", "메모")).firstMatch
            XCTAssertLessThan(memo.frame.maxX, 430, label)
        }
    }

    private func exerciseScreens(_ app: XCUIApplication, _ tag: String) {
        assertHomeLayout(app, tag)
        capture(app, "\(tag)-home")

        let menu = menuButton(app)
        menu.tap()
        sleep(1)
        capture(app, "\(tag)-menu")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(1)

        let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
        badge.tap()
        let strip = app.descendants(matching: .any)["mapHomeDateWeekStrip"]
        if strip.waitForExistence(timeout: 5) {
            if app.windows.firstMatch.frame.width >= wideWidth {
                XCTAssertLessThanOrEqual(strip.frame.width, 340, tag)
            }
            capture(app, "\(tag)-date-strip")
            badge.tap()
        }

        let calendar = app.buttons.matching(NSPredicate(format: "label == %@", "달력")).firstMatch
        if calendar.waitForExistence(timeout: 5) {
            calendar.tap()
            sleep(2)
            capture(app, "\(tag)-calendar")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
            sleep(1)
        }
    }

    /// 접고 펴거나 돌리면 같은 화면이 크기만 바뀐다. 그때 날짜·시트·재생이 끊기지 않는지 본다.
    func testRotationKeepsDateSheetAndPlayback() throws {
        let app = launchHome()
        let device = XCUIDevice.shared
        device.orientation = .portrait
        sleep(2)
        try XCTSkipIf(app.windows.firstMatch.frame.width < wideWidth, "세로만 지원하는 폭")

        let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
        let originalDate = badge.label
        badge.tap()
        let strip = app.descendants(matching: .any)["mapHomeDateWeekStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15))
        strip.swipeRight()
        sleep(1)
        let movedDate = badge.label
        XCTAssertNotEqual(movedDate, originalDate, "날짜 줄을 밀어도 날짜가 그대로다")

        rotate(app, to: .landscapeLeft)
        XCTAssertEqual(badge.label, movedDate, "돌린 뒤 선택 날짜가 바뀌었다")

        let calendar = app.buttons.matching(NSPredicate(format: "label == %@", "달력")).firstMatch
        calendar.tap()
        let weekday = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "20[0-9]{2}년 [0-9]+월")).firstMatch
        XCTAssertTrue(weekday.waitForExistence(timeout: 8), "달력 시트가 열리지 않았다")
        XCUIDevice.shared.orientation = .portrait
        sleep(4)
        XCTAssertTrue(weekday.exists, "돌렸더니 달력 시트가 닫혔다")
        capture(app, "rotated-keeps-calendar")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
        sleep(2)

        let play = app.buttons.matching(NSPredicate(format: "label == %@", "재생")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let pause = app.buttons.matching(NSPredicate(format: "label == %@", "멈춤")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "재생이 시작되지 않았다")
        device.orientation = .landscapeLeft
        sleep(1)
        XCTAssertTrue(pause.exists, "돌렸더니 재생이 멈췄다")
        capture(app, "rotated-keeps-playback")
        device.orientation = .portrait
    }

    func testLayoutAndOrientationFollowTheScreenWidth() throws {
        let app = launchHome()
        let device = XCUIDevice.shared
        device.orientation = .portrait
        sleep(2)
        let portrait = app.windows.firstMatch.frame.size
        let screenShortSide = min(portrait.width, portrait.height)
        exerciseScreens(app, "portrait")

        rotate(app, to: .landscapeLeft)
        let rotated = app.windows.firstMatch.frame.size
        if screenShortSide >= wideWidth {
            XCTAssertGreaterThan(rotated.width, rotated.height, "넓은 화면은 가로를 지원한다")
            exerciseScreens(app, "landscape")
        } else {
            XCTAssertLessThan(rotated.width, rotated.height, "좁은 화면은 세로만 지원한다")
            capture(app, "landscape-request-stays-portrait")
        }
        device.orientation = .portrait
        sleep(2)
    }
}
