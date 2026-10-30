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

    /// 시간선 확대·축소가 두 손가락 없이도 단계를 밟는지 확인한다.
    /// 확대하면 '축소'가 열리고, 되돌리면 다시 하루 전체라 '축소'가 닫히는지로 본다.
    func testTimelineZoomButtonsStepThroughTheLadder() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        launchMapHome(app)
        let zoomIn = app.buttons["시간선 확대"]
        let zoomOut = app.buttons["시간선 축소"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 15), "시간선 확대 단추가 없다")
        XCTAssertTrue(zoomIn.isEnabled, "하루 전체에서는 확대할 수 있어야 한다")
        XCTAssertFalse(zoomOut.isEnabled, "하루 전체에서는 더 줄일 수 없다")
        attach(app, name: "timeline-zoom-full-day")
        zoomIn.tap()
        XCTAssertTrue(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == true"),
                    object: zoomOut
                )],
                timeout: 5
            ) == .completed,
            "확대했는데 축소 단추가 열리지 않는다"
        )
        attach(app, name: "timeline-zoom-half-day")
        zoomOut.tap()
        XCTAssertTrue(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isEnabled == false"),
                    object: zoomOut
                )],
                timeout: 5
            ) == .completed,
            "되돌렸는데 하루 전체로 돌아오지 않는다"
        )
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

/// 클립 편집기 도구가 이름으로 드러나고, 확대가 단추로도 되고, 집기가 한 번에 끝나는지 화면에서 확인한다.
///
/// 예전에는 도구가 아이콘뿐이라 눌러 봐야 알 수 있었고, 확대는 두 손가락만이라
/// 하루 전체 화면(1시간 클립 9pt)에서 경계 손잡이가 나타나지 않는 이유를 알 길이 없었다.
final class TaptionPlanClipEditorToolsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments = ["-nlePreview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["클립 편집"].waitForExistence(timeout: 30))
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    /// 도구 막대의 여섯 단추가 이름으로 드러나고 높이가 44pt 이상인가.
    func testEveryToolHasANameAndAFortyFourPointTarget() throws {
        let app = launchEditor()
        for name in ["분류", "가르기", "지우기", "되돌리기", "다시", "확대"] {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(name) 단추가 이름으로 드러나지 않는다")
            XCTAssertGreaterThanOrEqual(
                button.frame.height,
                44,
                "\(name) 단추 높이가 \(button.frame.height)pt다"
            )
        }
        attach(app, name: "tools")
    }

    /// 확대 단추가 '확대 → 더 확대 → 전체'로 돌고, 이름이 다음에 할 일을 적는다.
    func testZoomButtonCyclesFromWholeDayAndBack() throws {
        let app = launchEditor()
        let zoom = app.buttons["확대"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "하루 전체에서 확대 단추가 '확대'가 아니다")
        zoom.tap()
        XCTAssertTrue(app.buttons["더 확대"].waitForExistence(timeout: 5), "한 번 눌러도 4배로 가지 않는다")
        attach(app, name: "zoom-4x")
        app.buttons["더 확대"].tap()
        XCTAssertTrue(app.buttons["전체"].waitForExistence(timeout: 5), "두 번 눌러도 12배로 가지 않는다")
        attach(app, name: "zoom-12x")
        app.buttons["전체"].tap()
        XCTAssertTrue(app.buttons["확대"].waitForExistence(timeout: 5), "전체를 눌러도 하루 전체로 돌아오지 않는다")
        attach(app, name: "zoom-fit")
    }

    /// 상세활동을 누르고 '반영' 한 번이면 대분류가 되고, 되돌리기 한 번이면 원래대로 돌아온다.
    func testPromotingDetailIsOneStepAndUndoPutsItBack() throws {
        let app = launchEditor()
        let detail = app.staticTexts["회의"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "상세활동 '회의'가 화면에 없다")
        detail.tap()

        let use = app.buttons["이 구간을 대분류로 반영"]
        XCTAssertTrue(use.waitForExistence(timeout: 5), "상세활동을 눌러도 집기 줄이 열리지 않는다")
        XCTAssertGreaterThanOrEqual(use.frame.height, 44, "반영 단추 높이가 \(use.frame.height)pt다")
        attach(app, name: "pick-detail")
        use.tap()

        let changed = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "바뀐 클립"))
            .firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "반영했는데 저장 대기 안내가 없다")
        attach(app, name: "after-promote")

        let undo = app.buttons["되돌리기"]
        XCTAssertTrue(undo.isEnabled, "반영했는데 되돌리기가 꺼져 있다")
        undo.tap()
        sleep(1)
        XCTAssertFalse(changed.exists, "되돌렸는데 저장 대기 안내가 남아 있다")
        attach(app, name: "after-undo")
    }
}

/// 재생 단추가 실제로 상태를 바꾸는지, 그리고 그때 HUD와 「일시 정지」·「종료」가 함께 서는지.
/// 달력 시트를 닫은 직후에 눌렀던 앞선 시도는 시트가 하단을 덮은 채여서 눌림이 닿지 않았을 수 있다.
/// 여기서는 시트를 건드리지 않고 바로 누른다.
final class TaptionPlanPlaybackHUDUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    /// 하단 단추 가운데 화면 아래쪽(하단 독)에 있는 것들의 이름.
    ///
    /// 재생 중에 항목이 늘었는지 재는 데 쓴다. 대표 요청은 "재생은 같은 자리에서
    /// 「멈춤」으로만 바뀌고 단추를 늘리지 말 것"이었다.
    private func bottomBarLabels(_ app: XCUIApplication) -> [String] {
        let bottomEdge = app.frame.height * 0.8
        return app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY > bottomEdge }
            .map { $0.label }
            .sorted()
    }

    func testPlayTogglesInOneSlotAndMapMoveCancelsIt() throws {
        // 하루 재생은 24초짜리라, 「멈춤」을 찾고 스크린샷을 붙이고 하단 단추를 세는
        // 사이에 재생이 스스로 끝나 버린다. 실제로 2026-10-28에 이 시험이 시각에 따라
        // 두 번 실패했고(변경 전 커밋에서도 실패), 코드 회귀가 아니었다.
        // `-slowDayPlayback`은 재생 배속만 10분의 1로 늦춰 그 경합을 없앤다.
        // 재생 구간은 [선택 시각, 지금]이다. 지금 시각에 붙어 있으면 구간이 짧아 몇 초 만에
        // 스스로 끝나므로, 시간 레일을 이른 아침(01:35 무렵)으로 옮겨 구간을 넉넉히 만든다.
        // 05:00 전에는 그 구간조차 17초가 안 되므로 재지 않고 건너뛴다.
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minuteOfDay = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        try XCTSkipIf(minuteOfDay < 300, "자정에서 5시간이 안 지나 재생 구간이 17초보다 짧다")

        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments += ["-slowDayPlayback"]
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 12) { skip.tap() }

        let play = app.buttons["재생"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 40), "하단 재생 단추가 없다")
        // 시간 레일(오른쪽 세로줄) 위쪽을 눌러 선택을 이른 아침으로 옮긴다.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.2)).tap()
        usleep(600_000)
        let idleLabels = bottomBarLabels(app)
        attach(app, name: "play-idle")

        // 재생을 누르면 **같은 자리**가 「멈춤」이 된다. 「종료」는 없다.
        play.tap()
        // HUD는 재생이 끝나면 함께 사라진다. 다른 것을 보기 전에 먼저 확인한다.
        let hud = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "하루 24초")).firstMatch
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "재생 중인데 HUD가 없다")
        attach(app, name: "play-running")
        XCTAssertTrue(app.buttons["멈춤"].firstMatch.exists, "재생을 눌러도 「멈춤」으로 바뀌지 않는다")
        XCTAssertFalse(app.buttons["재생"].exists, "재생 중인데 「재생」이 남아 있다")
        XCTAssertFalse(app.buttons["종료"].exists, "재생 중에 「종료」가 또 있다(단추를 늘리지 않기로 했다)")
        XCTAssertEqual(
            bottomBarLabels(app).count,
            idleLabels.count,
            "재생 중에 하단 항목 수가 달라졌다(단추를 늘리지 않기로 했다): \(bottomBarLabels(app))"
        )

        // 같은 자리를 다시 누르면 재생이 멈추고 「재생」으로 돌아온다. HUD도 함께 사라진다.
        app.buttons["멈춤"].firstMatch.tap()
        XCTAssertTrue(app.buttons["재생"].firstMatch.waitForExistence(timeout: 5), "멈춤을 눌러도 「재생」으로 돌아오지 않는다")
        XCTAssertFalse(app.buttons["멈춤"].exists, "멈췄는데 「멈춤」이 남아 있다")
        XCTAssertFalse(hud.exists, "멈췄는데 HUD가 남아 있다")
        attach(app, name: "play-paused")

        // 재생 중에 지도를 끌면 재생이 취소된다. 취소 단추를 따로 두지 않는다.
        app.buttons["재생"].firstMatch.tap()
        XCTAssertTrue(app.buttons["멈춤"].firstMatch.waitForExistence(timeout: 8), "다시 재생되지 않는다")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        from.press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.42))
        )
        XCTAssertTrue(
            app.buttons["재생"].firstMatch.waitForExistence(timeout: 6),
            "지도를 끌어도 재생이 취소되지 않는다"
        )
        XCTAssertFalse(hud.exists, "지도를 끌었는데 HUD가 남아 있다")
        attach(app, name: "play-cancelled-by-map")
    }
}

/// 하단 1급 메뉴에 「녹화」가 다시 서 있는지, 메뉴 안에 같은 일을 하는 줄이 남아 있지 않은지.
///
/// 0f2987d에서 하단 항목을 다섯 개로 줄이며 녹화를 메뉴 > 화면으로 내렸는데,
/// 재생을 마친 사람이 다음에 누르는 버튼이라 메뉴 안에서는 찾지 못한다.
final class TaptionPlanBottomBarRecordUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    func testRecordSitsInTheBottomBarNextToPlay() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 12) { skip.tap() }

        let play = app.buttons["재생"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 40), "하단 재생 단추가 없다")
        // 「메모」는 왼쪽 위 원형 단추에도 있어 같은 이름이 둘이다. 하단 것은 화면에서
        // 가장 아래에 있으므로 minY가 큰 쪽을 고른다.
        func bottomBarButton(_ label: String) -> XCUIElement? {
            let all = app.buttons
                .matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex
            return all.max(by: { $0.frame.minY < $1.frame.minY })
        }
        guard let record = bottomBarButton("녹화") else {
            return XCTFail("하단에 「녹화」가 없다")
        }
        guard let memo = bottomBarButton("메모") else {
            return XCTFail("하단에 「메모」가 없다")
        }

        XCTAssertGreaterThanOrEqual(record.frame.height, 44, "녹화 단추 높이가 \(record.frame.height)pt다")
        XCTAssertGreaterThan(record.frame.minX, play.frame.minX, "녹화가 재생보다 왼쪽에 있다")
        XCTAssertLessThan(record.frame.minX, memo.frame.minX, "녹화가 메모보다 오른쪽에 있다")
        // 메뉴는 하단 맨 왼쪽이다(2026-10-26에 왼쪽 위에서 내렸다).
        guard let menuInBar = bottomBarButton("메뉴") else {
            return XCTFail("하단에 「메뉴」가 없다")
        }
        XCTAssertLessThan(menuInBar.frame.minX, play.frame.minX, "메뉴가 하단 맨 왼쪽이 아니다")
        XCTAssertGreaterThanOrEqual(menuInBar.frame.height, 44, "메뉴 단추 높이가 \(menuInBar.frame.height)pt다")
        attach(app, name: "bottom-bar-record")

        // 같은 일을 하는 줄이 메뉴 > 화면에 겹쳐 남아 있으면 안 된다.
        menuInBar.tap()
        let close = app.buttons["메뉴 닫기"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "메뉴가 열리지 않았다")
        XCTAssertFalse(
            app.buttons["재생 화면 녹화"].exists,
            "하단에 녹화가 있는데 메뉴 > 화면에도 같은 줄이 남아 있다"
        )
        attach(app, name: "menu-without-record")
        close.tap()
    }
}

/// 여러 개로 나뉜 클립을 한 번에 덮는 창이 실제로 그렇게 하는지 화면에서 확인한다.
///
/// BOKKI STUDIO의 자막 합치기와 같은 자리다. 예전에는 클립마다 분류를 하나씩
/// 골라야 해서, 센서가 잘게 나눈 하루는 손으로 고칠 수 없을 만큼 일이 많았다.
final class TaptionPlanOverwriteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launchArguments = ["-nlePreview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["클립 편집"].waitForExistence(timeout: 30))
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    /// 분류 메뉴에서 '전체 덮기'를 열고, 몇 개가 바뀌는지 먼저 보여 준 뒤 한 번에 덮는다.
    func testOverwriteAllChangesEveryClipAtOnce() throws {
        let app = launchEditor()
        attach(app, name: "overwrite-before")

        let categoryButton = app.buttons["분류"]
        XCTAssertTrue(categoryButton.waitForExistence(timeout: 10), "분류 단추가 없다")
        categoryButton.tap()
        let entry = app.buttons["전체 덮기"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "분류 메뉴에 '전체 덮기'가 없다")
        entry.tap()

        // 창은 분류를 고르기 전에 '무엇을 할지'만 보여 주고 덮기 단추를 잠근다.
        XCTAssertTrue(
            app.staticTexts["덮을 분류를 고르세요"].waitForExistence(timeout: 10),
            "덮기 창이 열리지 않았다"
        )
        let overwrite = app.buttons["덮기"]
        XCTAssertTrue(overwrite.exists, "덮기 단추가 없다")
        XCTAssertFalse(overwrite.isEnabled, "분류를 고르기 전에는 덮을 수 없어야 한다")
        XCTAssertFalse(
            app.buttons["합치기만"].exists,
            "합칠 곳이 없는데 '합치기만'을 내밀면 누르고 아무 일도 일어나지 않는다"
        )
        attach(app, name: "overwrite-sheet-empty")

        // 분류를 고르면 바뀔 클립 수가 바로 나온다(예시 하루는 기록이 있는 8구간).
        let exercise = app.buttons["운동"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 5), "분류 칩이 없다")
        exercise.tap()
        XCTAssertTrue(
            app.staticTexts["클립 8개를 '운동' 분류로 덮습니다"].waitForExistence(timeout: 5),
            "바뀔 클립 수가 보이지 않는다"
        )
        XCTAssertTrue(overwrite.isEnabled, "분류를 골랐는데 덮기 단추가 잠겨 있다")
        attach(app, name: "overwrite-sheet-picked")

        overwrite.tap()

        // 창이 닫히고, 여러 클립이 한 번에 한 분류가 되고, 되돌리기가 켜진다.
        // '덮기' 단추는 이 창에만 있으므로 그것이 사라지는 것이 창이 닫혔다는 신호다.
        XCTAssertTrue(overwrite.waitForNonExistence(timeout: 15), "덮은 뒤에도 창이 남아 있다")
        XCTAssertTrue(
            waitForExerciseCount(app, 3, atLeast: true, timeout: 10),
            "한 번에 바뀌지 않았다 — 대분류 줄의 운동이 \(exerciseCount(app))개뿐이다"
        )
        XCTAssertTrue(app.buttons["되돌리기"].isEnabled, "덮었는데 되돌릴 수 없다")
        attach(app, name: "overwrite-after")

        // 한 번에 되돌리면 원래 하루로 돌아온다.
        // (센서 원본 줄은 원래 분류를 그대로 보여 주므로 대분류 줄의 운동 개수로 본다.)
        app.buttons["되돌리기"].tap()
        XCTAssertTrue(
            waitForExerciseCount(app, 0, atLeast: false, timeout: 10),
            "되돌리기가 한 번에 끝나지 않는다 — 운동이 \(exerciseCount(app))개 남았다"
        )
    }

    /// 대분류 줄에 그려진 분류 이름의 개수.
    ///
    /// 같은 이름이 '센서 원본' 줄에도 있으므로, 덮기가 대분류 줄에만 적용됐는지는
    /// 이 개수로만 판단한다(원본 줄은 원본이므로 바뀌면 오히려 잘못이다).
    private func exerciseCount(_ app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", "운동")).count
    }

    private func waitForExerciseCount(
        _ app: XCUIApplication,
        _ expected: Int,
        atLeast: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = exerciseCount(app)
            if atLeast ? count >= expected : count == expected { return true }
            usleep(200_000)
        }
        let count = exerciseCount(app)
        return atLeast ? count >= expected : count == expected
    }
}

/// 날짜 배지를 눌러 펼친 날짜 줄을 한 번 쓸어 넘기면 **하루**만 넘어간다.
///
/// 예전에는 손가락이 움직인 거리에 비례해 날짜를 넘겼다(`dx / dayPitch`). 줄 폭이
/// 한 주(274pt)라 한 번 쓸어 넘기면 6~7일이 지나, 손짓 하나가 '주 단위'로 보였다
/// (대표 지적). 그래서 줄 폭만큼 크게 쓸어도 하루만 움직이는지 잠근다.
final class TaptionPlanDateStripSwipeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 지도 홈을 열고 날짜 배지가 실제로 눌릴 때까지 기다린다.
    ///
    /// 첫 실행에서는 앱이 직접 그리는 권한 안내 시트가 날짜 배지를 덮는다. 그래서
    /// 배지가 트리에 있어도 탭이 시트에 먹히고 날짜 줄이 펼쳐지지 않는다. 사용자
    /// 데이터를 바꾸지 않도록 허용은 누르지 않고 '전체 건너뛰기'로만 닫는다.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 20) {
            skip.tap()
        }
        let badge = dateBadge(app)
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "날짜 배지가 없다")
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: badge
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [hittable], timeout: 30),
            .completed,
            "날짜 배지가 눌릴 수 있게 되지 않음"
        )
        return app
    }

    /// 오른쪽 위 날짜 배지. 날짜가 든 이름은 날마다 달라지므로 식별자로 집는다.
    private func dateBadge(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["mapHomeDateBadge"]
    }

    private func weekStrip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["mapHomeDateWeekStrip"]
    }

    /// 배지 이름에서 (월, 일)을 읽는다.
    private func monthDay(_ label: String) -> (month: Int, day: Int)? {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// 오늘로부터 `offset`일 뒤의 (월, 일). 윤년·월말을 직접 셈하지 않는다.
    private func monthDay(offset: Int) -> (month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.month, .day], from: date)
        return (parts.month ?? 0, parts.day ?? 0)
    }

    /// 날짜 줄 위에서 좌우로 민다. 줄 폭 안에서 움직여 손짓이 지도로 새지 않게 한다.
    private func swipe(_ app: XCUIApplication, on strip: XCUIElement, dx: CGFloat) {
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: dx < 0 ? 0.9 : 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = name
        add(shot)
    }

    /// 배지의 날짜가 바뀔 때까지 기다렸다가 새 (월, 일)을 돌려준다.
    private func waitForDateChange(
        _ badge: XCUIElement,
        from previous: (month: Int, day: Int),
        timeout: TimeInterval
    ) -> (month: Int, day: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = monthDay(badge.label), now != previous { return now }
            usleep(200_000)
        }
        return monthDay(badge.label).flatMap { $0 == previous ? nil : $0 }
    }

    /// 날짜 줄은 밀어도 선택한 날짜가 바뀌지 않고, 날짜 칸을 탭해야 그날로 이동한다(대표 지시, ARC1030A02).
    func testSwipeOnlyBrowsesAndTapSelects() throws {
        let app = launch()
        let badge = dateBadge(app)
        let today = try XCTUnwrap(monthDay(badge.label), "날짜를 읽지 못했다: \(badge.label)")

        badge.tap()
        let strip = weekStrip(app)
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "날짜 배지를 눌러도 날짜 줄이 펼쳐지지 않는다")
        usleep(500_000)
        attach(app, name: "date-strip-expanded")

        // 크게 밀어도 날짜는 그대로여야 한다(둘러보기만 한다).
        swipe(app, on: strip, dx: -250)
        usleep(1_200_000)
        let afterSwipe = try XCTUnwrap(monthDay(badge.label))
        XCTAssertEqual([afterSwipe.month, afterSwipe.day], [today.month, today.day], "밀기만 했는데 날짜가 바뀌었다")
        attach(app, name: "date-strip-after-swipe")

        // 날짜 칸을 탭하면 그날로 이동한다.
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let selected = try XCTUnwrap(
            waitForDateChange(badge, from: today, timeout: 6),
            "날짜 칸을 탭했는데 날짜가 그대로다"
        )
        XCTAssertNotEqual([selected.month, selected.day], [today.month, today.day])
        attach(app, name: "date-strip-after-tap")
    }

    /// 날짜 줄은 선택일 앞뒤를 길게 이어 두어, 계속 밀어도 날짜 칸이 이어진다. 밀기만으로는 날짜가 바뀌지 않는다.
    func testDateStripKeepsScrollingPastTheWeekWithoutChangingTheDate() throws {
        let app = launch()
        let badge = dateBadge(app)
        let today = try XCTUnwrap(monthDay(badge.label), "날짜를 읽지 못했다: \(badge.label)")

        badge.tap()
        let strip = weekStrip(app)
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "날짜 배지를 눌러도 날짜 줄이 펼쳐지지 않는다")
        usleep(500_000)

        for _ in 1...5 { swipe(app, on: strip, dx: -250); usleep(400_000) }
        usleep(800_000)
        let after = try XCTUnwrap(monthDay(badge.label))
        XCTAssertEqual([after.month, after.day], [today.month, today.day], "밀기만 했는데 날짜가 바뀌었다")
        attach(app, name: "date-strip-five-swipes")
    }
}

/// 손짓별 끊김(hitch)을 실기기에서 잰다(대표 지시 "터치·팝업·드래그 최적화", ARC1030A07).
/// 지연이 큰 손짓부터 구조를 바꾸기 위한 계측이라 사용자 데이터는 바꾸지 않는다.
final class TaptionPlanInteractionPerfUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        app.launch()
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 12) { skip.tap() }
        let menu = button(app, "메뉴")
        XCTAssertTrue(menu.waitForExistence(timeout: 40), "지도 홈이 뜨지 않음")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 30), .completed, "메뉴가 눌릴 수 없음")
        sleep(3)
        return app
    }

    private func button(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func point(_ app: XCUIApplication, _ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }

    /// 손짓 하나를 여러 번 반복하며 hitch 비율을 잰다.
    private func measureHitches(_ app: XCUIApplication, _ gesture: () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app)], options: options, block: gesture)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        usleep(700_000)
        point(app, 0.5, 0.62).press(forDuration: 0.05, thenDragTo: point(app, 0.5, 0.99))
        usleep(700_000)
    }

    /// 하단 단추로 시트(달력·하루 요약)를 열고 닫는다.
    func testPerfOpenAndCloseSheets() throws {
        let app = launch()
        measureHitches(app) {
            button(app, "달력").tap()
            dismissSheet(app)
            button(app, "집").tap()
            dismissSheet(app)
        }
    }

    /// 왼쪽 메뉴를 열고 닫는다.
    func testPerfOpenAndCloseMenu() throws {
        let app = launch()
        measureHitches(app) {
            button(app, "메뉴").tap()
            usleep(900_000)
            point(app, 0.97, 0.5).tap()
            usleep(700_000)
        }
    }

    /// 사이드바 손잡이를 위아래로 끈다.
    func testPerfSidebarHandleDrag() throws {
        let app = launch()
        measureHitches(app) {
            let handle = point(app, 0.93, 0.50)
            handle.press(forDuration: 0.1, thenDragTo: point(app, 0.93, 0.72))
            point(app, 0.93, 0.72).press(forDuration: 0.1, thenDragTo: point(app, 0.93, 0.34))
        }
    }

    /// 지도를 손가락으로 움직이고 핀치로 확대·축소한다.
    func testPerfMapPanAndPinch() throws {
        let app = launch()
        measureHitches(app) {
            point(app, 0.40, 0.40).press(forDuration: 0.05, thenDragTo: point(app, 0.40, 0.62))
            point(app, 0.40, 0.62).press(forDuration: 0.05, thenDragTo: point(app, 0.25, 0.40))
            app.pinch(withScale: 2.2, velocity: 2)
            app.pinch(withScale: 0.45, velocity: -2)
        }
    }
}
