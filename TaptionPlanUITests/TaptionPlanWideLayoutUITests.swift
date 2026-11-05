import XCTest

/// 넓은 화면 배치와 방향 규칙을 실제 화면에서 잠근다. 폭으로 기대값을 가르므로 어느 기기에서든 돈다.
/// `TEST_RUNNER_WIDE_CAPTURE_DIR`을 주면 화면을 그 폴더에 남긴다.
final class TaptionPlanWideLayoutUITests: XCTestCase {
    private let wideWidth: CGFloat = 600

    private func launchHome(extraArguments: [String] = [], waitsForMap: Bool = true) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        // 시뮬레이터 설정에 남은 이전 폭·높이 고정이 다음 실행을 흔들지 않게 항상 값을 준다.
        let viewportResets = ["-debugViewportWidth", "-debugViewportHeight"].filter { !extraArguments.contains($0) }.flatMap { [$0, "0"] }
        app.launchArguments += ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-slowDayPlayback"] + viewportResets + extraArguments
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 20) { skip.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons["허용 안 함"]
        if decline.waitForExistence(timeout: 3) { decline.tap() }
        guard waitsForMap else { return app }
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

    private func topLeftGoogleButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Google Calendar")).firstMatch
    }

    private func panel(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["mapHomeWidePanel"].firstMatch
    }

    /// 넓은 폭의 패널: 왼쪽 열에서 하단 메뉴 위에 서고, 하단 메뉴·날짜 배지가 그대로 눌린다.
    private func assertPanelBesideMap(_ app: XCUIApplication, maxWidth: CGFloat, _ label: String) {
        let frame = panel(app).frame
        XCTAssertTrue(panel(app).exists, label)
        XCTAssertLessThan(frame.minX, 40, label)
        XCTAssertLessThanOrEqual(frame.width, maxWidth, label)
        XCTAssertLessThanOrEqual(frame.maxY, menuButton(app).frame.minY, label)
        XCTAssertTrue(menuButton(app).isHittable, label)
        XCTAssertTrue(app.descendants(matching: .any)["mapHomeDateBadge"].isHittable, label)
    }

    private func closePanel(_ app: XCUIApplication) {
        app.buttons.matching(NSPredicate(format: "label == %@", "패널 닫기")).firstMatch.tap()
        sleep(1)
    }

    private func exerciseScreens(_ app: XCUIApplication, _ tag: String) {
        assertHomeLayout(app, tag)
        capture(app, "\(tag)-home")
        let isWide = app.windows.firstMatch.frame.width >= wideWidth

        let menu = menuButton(app)
        menu.tap()
        sleep(1)
        capture(app, "\(tag)-menu")
        if isWide {
            // 가로는 메뉴를 두 열로 펴서 스크롤 없이 보인다.
            let window = app.windows.firstMatch.frame
            assertPanelBesideMap(app, maxWidth: window.width > window.height ? 690 : 410, "\(tag) 메뉴")
            app.buttons.matching(NSPredicate(format: "label == %@", "메뉴 닫기")).firstMatch.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        sleep(1)

        let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
        badge.tap()
        let strip = app.descendants(matching: .any)["mapHomeDateWeekStrip"]
        if strip.waitForExistence(timeout: 5) {
            // 아이폰 폭은 날짜 줄이 왼쪽 위 자리를 덮어 버튼을 숨기고, 넓은 폭은 그대로 둔다.
            XCTAssertEqual(topLeftGoogleButton(app).exists, isWide, tag)
            if isWide {
                XCTAssertLessThanOrEqual(strip.frame.width, 600, tag) // 스크롤 내용 폭까지 잡혀서 보이는 폭은 캡처로 확인한다.
            }
            capture(app, "\(tag)-date-strip")
            badge.tap()
        }

        let calendar = app.buttons.matching(NSPredicate(format: "label == %@", "달력")).firstMatch
        if calendar.waitForExistence(timeout: 5) {
            calendar.tap()
            sleep(2)
            capture(app, "\(tag)-calendar")
            if isWide {
                let expected: CGFloat = app.windows.firstMatch.frame.width >= 1050 ? 690 : 410
                assertPanelBesideMap(app, maxWidth: expected, "\(tag) 달력")
                closePanel(app)
            } else {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
                sleep(1)
            }
        }
    }

    /// 분할 화면 폭: 패널이 왼쪽 열에 서고 시간 사이드바가 그대로 보인다(시험용 폭 고정).
    func testSplitWidthsKeepPanelAndSidebar() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        for width in ["600", "700"] {
            let app = launchHome(extraArguments: ["-debugViewportWidth", width])
            let tag = "split\(width)"
            let menu = menuButton(app)
            menu.tap()
            sleep(1)
            let panelFrame = panel(app).frame
            XCTAssertLessThanOrEqual(panelFrame.width, 410, tag)
            XCTAssertLessThan(panelFrame.maxX, CGFloat(Int(width)!) - 100, "\(tag) 패널이 사이드바를 가린다")
            capture(app, "\(tag)-menu")
            let calendar = app.buttons.matching(NSPredicate(format: "label == %@", "달력")).firstMatch
            calendar.tap()
            sleep(2)
            capture(app, "\(tag)-calendar")
            XCTAssertLessThanOrEqual(panel(app).frame.width, 410, tag)
            app.terminate()
        }
    }

    /// 가로에서는 메인 메뉴가 스크롤 없이 마지막 줄까지 보인다. 패널은 상단 버튼 줄 아래에 서고, 세로도 같은 자리다.
    /// 듀오 안쪽은 실제 펼침을 띄울 수 없어 폭·높이를 고정해 본다.
    func testMenuStaysBelowTopRowAndLandscapeFitsWithoutScrolling() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        for (tag, orientation, arguments) in [
            ("ipad-portrait", UIDeviceOrientation.portrait, [String]()),
            ("ipad-landscape", .landscapeLeft, []),
            ("duo-portrait", .portrait, ["-debugViewportWidth", "669", "-debugViewportHeight", "951"]),
            ("duo-landscape", .landscapeLeft, ["-debugViewportWidth", "951", "-debugViewportHeight", "669"]),
        ] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            let app = launchHome(extraArguments: arguments)
            sleep(2)
            menuButton(app).tap()
            sleep(2)
            capture(app, "menu-\(tag)")
            let panelFrame = panel(app).frame
            let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "빌드")).firstMatch
            print("MENU-FIT \(tag) panel=\(panelFrame) footer=\(footer.frame)")
            XCTAssertGreaterThan(panelFrame.minY, 60, "\(tag) 메뉴가 상단 버튼 줄을 덮었다")
            XCTAssertTrue(topLeftGoogleButton(app).isHittable, tag)
            if orientation.isLandscape {
                // 듀오 가로에 권한 카드까지 있으면 맨 아래 상태·버전 줄만 넘칠 수 있어 메뉴 항목으로 잰다(시뮬레이터는 권한이 없어 카드가 뜬다).
                let lastRow = tag == "ipad-landscape" ? footer : app.buttons.matching(NSPredicate(format: "label == %@", "지도 출처")).firstMatch
                XCTAssertLessThanOrEqual(lastRow.frame.maxY, panelFrame.maxY, "\(tag) 스크롤해야 보인다")
                let firstColumnLast = app.staticTexts["내 차 등록"].firstMatch
                XCTAssertLessThanOrEqual(firstColumnLast.frame.maxY, panelFrame.maxY, "\(tag) 왼쪽 열이 잘린다")
            }
            app.buttons.matching(NSPredicate(format: "label == %@", "메뉴 닫기")).firstMatch.tap()
            sleep(1)
            // 날짜 줄을 펼쳐도 왼쪽 위 버튼을 덮지 않으니 그대로 둔다.
            let badge = app.descendants(matching: .any)["mapHomeDateBadge"]
            badge.tap()
            XCTAssertTrue(app.descendants(matching: .any)["mapHomeDateWeekStrip"].waitForExistence(timeout: 5), tag)
            sleep(1)
            capture(app, "date-strip-\(tag)")
            XCTAssertTrue(topLeftGoogleButton(app).isHittable, "\(tag) 날짜 줄을 펴자 왼쪽 위 버튼이 숨었다")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testDaySummaryPanelAndGrowthPage() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        let app = launchHome(extraArguments: ["-debugOpenDaySummary"], waitsForMap: false)
        let summary = app.staticTexts["하루 요약"]
        XCTAssertTrue(summary.waitForExistence(timeout: 40))
        assertPanelBesideMap(app, maxWidth: 410, "하루 요약")
        capture(app, "day-summary")
        app.buttons["daySummaryGrowthCard"].firstMatch.tap()
        let growthTitle = app.staticTexts["우리 집 성장"]
        XCTAssertTrue(growthTitle.waitForExistence(timeout: 10))
        sleep(1)
        capture(app, "growth-page")
        // 집 성장은 패널 안에서 넘어가고 잘리지 않는다.
        XCTAssertGreaterThan(growthTitle.frame.minX, panel(app).frame.minX)
        XCTAssertLessThan(growthTitle.frame.maxX, panel(app).frame.maxX)
        app.buttons.matching(NSPredicate(format: "label == %@", "뒤로")).firstMatch.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
    }

    func testDailyCardOpensInThePanel() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        let app = launchHome()
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        menuButton(app).tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label == %@", "하루 카드")).firstMatch.tap()
        sleep(4)
        assertPanelBesideMap(app, maxWidth: 410, "하루 카드")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "메뉴 닫기")).firstMatch.exists, "메뉴가 함께 열려 있다")
        capture(app, "daily-card")
        closePanel(app)
    }

    func testClipEditorUsesColumnsOnWideScreens() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        let app = launchHome(extraArguments: ["-debugOpenClipEditor"], waitsForMap: false)
        let apply = app.buttons["적용"]
        XCTAssertTrue(apply.waitForExistence(timeout: 60))
        sleep(2)
        capture(app, "clip-editor-portrait")
        // 오른쪽 열에 도구가 모인다.
        XCTAssertGreaterThan(apply.frame.minX, app.windows.firstMatch.frame.width - 402)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        capture(app, "clip-editor-landscape")
        XCTAssertGreaterThan(apply.frame.minX, app.windows.firstMatch.frame.width - 402)
        XCUIDevice.shared.orientation = .portrait
    }

    /// 접고 펴거나 돌리면 같은 화면이 크기만 바뀐다. 그때 날짜·시트·재생이 끊기지 않는지 본다.
    func testRotationKeepsDateSheetAndPlayback() throws {
        try XCTSkipIf(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < wideWidth, "넓은 화면 전용")
        let app = launchHome()
        let device = XCUIDevice.shared
        device.orientation = .portrait
        sleep(2)

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
        closePanel(app)

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
