import XCTest

/// 실기기에서 앱이 올라와 홈 화면을 그리는지 확인한다.
/// 사용자 데이터를 바꾸는 동작(저장·삭제·권한 허용)은 하지 않는다.
final class TaptionPlanSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 지도 홈이 뜨고 하단 바가 눌릴 수 있게 될 때까지 기다린다.
    ///
    /// 첫 실행에서는 앱이 직접 띄우는 권한 안내 시트가 하단 바를 덮는다. 이건
    /// 시스템 HealthKit 시트가 아니라 앱이 그리는 시트라서, '허용 안 함'을 눌러도
    /// 닫히지 않고 '전체 건너뛰기'로만 닫힌다. 사용자 데이터를 바꾸지 않도록
    /// 허용은 누르지 않고 건너뛰기만 누른다.
    private func launchMapHome(_ app: XCUIApplication) {
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 12) {
            skip.tap()
        }
        let menu = app.buttons
            .containing(NSPredicate(format: "label CONTAINS %@", "메뉴"))
            .firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        // 전체 스위트를 한 번에 돌리면 런치 오버레이가 늦게 걷힌다. 그때 메뉴는
        // 트리에 있지만 눌리지 않아, 이어지는 탭이 조용히 아무 일도 하지 않는다.
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: menu
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [hittable], timeout: 30),
            .completed,
            "지도 홈 메뉴가 눌릴 수 있게 되지 않음"
        )
    }

    @discardableResult
    private func openMapHome(_ app: XCUIApplication) -> XCUIElement {
        launchMapHome(app)
        return app.buttons
            .containing(NSPredicate(format: "label CONTAINS %@", "메뉴"))
            .firstMatch
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
        let menu = openMapHome(app)
        menu.tap()
        let settings = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "설정")).firstMatch
        if settings.waitForExistence(timeout: 5) { settings.tap() }
        // '로그 업로드'는 '데이터 보호' 시트 안에 있다. 'GPS 및 센서 데이터'는
        // 화면을 여는 항목이 아니라 그 자리에서 펼쳐지는 섹션이라 아무 데도 가지 않는다.
        let dataProtection = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "데이터 보호")).firstMatch
        var tries = 0
        while !dataProtection.exists && tries < 6 {
            app.swipeUp()
            tries += 1
        }
        if dataProtection.waitForExistence(timeout: 5) { dataProtection.tap() }
        let upload = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "로그 보내기", "로그 업로드")).firstMatch
        tries = 0
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
        let menu = openMapHome(app)
        menu.tap()
        let alerts = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "알림")).firstMatch
        // 메뉴 시트는 스크롤 위치가 실행마다 다르다. 한 번 더 기다렸다가 넘긴다.
        var tries = 0
        while !alerts.waitForExistence(timeout: 2) && tries < 15 {
            app.swipeUp()
            tries += 1
        }
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
        let menu = openMapHome(app)
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
        let menu = openMapHome(app)
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
        launchMapHome(app)
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

    /// 메모 추가 → 음성 첨부 → 녹음 시작·끝내기(충돌 재현). 권한 창은 허용한다.
    func testMemoVoiceRecordReproduction() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        launchMapHome(app)
        let add = app.buttons.containing(NSPredicate(format: "label == %@ OR label == %@", "메모", "Memo")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        sleep(2)
        let voice = app.buttons.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "음성 첨부", "Voice attachment")).firstMatch
        if voice.waitForExistence(timeout: 8) { voice.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "허용", "Allow")).firstMatch
            if allow.waitForExistence(timeout: 4) { allow.tap() }
        }
        sleep(4)
        let stop = app.buttons.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "녹음 중", "Recording")).firstMatch
        if stop.waitForExistence(timeout: 5) { stop.tap() }
        sleep(8)
    }

    /// 집이 없을 때 알림이 안내한 목적지(메뉴 > 위치)로 바로 데려가는지 확인한다.
    /// 집이 등록된 기기에서는 이 테스트가 성립하지 않으므로 알림이 없으면 건너뛴다.
    func testHomeMissingAlertOpensLocationSettings() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        launchMapHome(app)
        // 하단 바의 집 버튼은 화면에서 가장 아래에 있다(지도 마커와 구분).
        let homes = app.buttons
            .matching(NSPredicate(format: "label == %@", "집"))
            .allElementsBoundByIndex
        guard let home = homes.max(by: { $0.frame.minY < $1.frame.minY }) else {
            return XCTFail("하단 집 버튼이 없다")
        }
        home.tap()
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else {
            throw XCTSkip("집이 이미 등록돼 있어 알림이 뜨지 않는다")
        }
        attach(app, name: "home-missing-alert")
        let open = alert.buttons["위치 설정 열기"]
        XCTAssertTrue(open.waitForExistence(timeout: 3), "알림에 다음 행동 버튼이 없다")
        open.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "등록된 사용자 위치"))
                .firstMatch
                .waitForExistence(timeout: 5),
            "메뉴 > 위치가 펼쳐지지 않았다"
        )
        attach(app, name: "menu-location")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }
}

/// 클립 편집기의 대분류 경계가 롤로 움직이는지 화면에서 확인한다.
///
/// `-nlePreview`로 하루 예시 구간(수면 00–07, 업무 07–12 …)을 바로 연다.
/// 경계를 위로 밀면 업무가 늘고 수면이 줄어야 한다 — 예전에는 업무만 줄고 늘지는 못했다.
final class TaptionPlanClipRollUITests: XCTestCase {
    /// 화면에 그려진 클립 구간 표시(예: `00:00–07:00`)를 모두 모은다.
    private func ranges(_ app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "label MATCHES %@", "\\d\\d:\\d\\d–\\d\\d:\\d\\d")
        return app.staticTexts.matching(predicate).allElementsBoundByIndex.map { $0.label }
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments = ["-nlePreview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["클립 편집"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["00:00–07:00"].waitForExistence(timeout: 10))
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    /// 긴 클립(업무)의 시작 손잡이를 위로 밀면 수면이 그만큼 줄고 업무는 늘어난다.
    func testRollEditMovesBothClipsAtTheBoundary() throws {
        let app = launchEditor()
        attach(app, name: "roll-before")

        let handle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "시작 자르기"))
            .firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "경계 손잡이가 접근성에 드러나지 않는다")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -10)))
        sleep(1)
        attach(app, name: "roll-after")

        let after = ranges(app)
        XCTAssertFalse(after.contains("00:00–07:00"), "수면 끝이 따라 줄지 않았다: \(after)")
        XCTAssertFalse(after.contains("07:00–12:00"), "업무 시작이 움직이지 않았다: \(after)")
        XCTAssertTrue(
            after.contains { $0.hasSuffix("–12:00") && $0 != "07:00–12:00" },
            "업무 끝이 12:00에서 따라 움직였다: \(after)"
        )
    }

    /// 하루 전체를 볼 때 1시간짜리 클립(식사)은 제목도 손잡이도 그리지 않는다(높이 22pt).
    /// 그래도 경계를 잡으면 맞닿은 이웃과 맞물려 밀려야 한다(통째로 옮겨지면 안 된다).
    func testRollWorksFromAShortClipWithoutHandles() throws {
        let app = launchEditor()
        // 고른 클립(업무)의 끝 손잡이는 경계 바로 3pt 위에 놓인다. 그 아래가 12:00 경계다.
        let endHandle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "끝 자르기"))
            .firstMatch
        XCTAssertTrue(endHandle.waitForExistence(timeout: 5), "업무 끝 손잡이가 없다")
        let boundaryY = endHandle.frame.maxY + 3

        // 경계에서 2pt 아래, 대분류 줄 한가운데를 잡는다 — 제목이 없어 좌표로만 닿는다.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 100, dy: boundaryY + 2))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -40)))
        sleep(1)
        attach(app, name: "short-clip-after")

        let after = ranges(app)
        XCTAssertFalse(after.contains("07:00–12:00"), "업무 끝이 그대로다: \(after)")
        guard let work = after.first(where: { $0.hasPrefix("07:00–") }) else {
            return XCTFail("업무 구간이 사라졌다: \(after)")
        }
        // "07:00–10:2x" → 경계는 10:2x. 식사는 그 경계에서 시작해 13:00에서 끝나야 한다.
        let boundary = String(work.dropFirst(6))
        XCTAssertNotEqual(boundary, "12:00", "업무 끝이 움직이지 않았다: \(after)")
        XCTAssertTrue(
            after.contains { $0 == "\(boundary)–13:00" },
            "식사가 같은 경계(\(boundary))에서 시작하지 않는다 — 한쪽만 움직였다: \(after)"
        )
    }
}
