import XCTest

/// 연봉 카운터 설정에서 용돈을 넣으면 환산 시급이 보이고, 지도 카운터에 용돈 줄이 뜬다.
final class TaptionPlanAllowanceUITests: XCTestCase {
    private func label(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAllowanceInputShowsHourlyRateAndCounterRow() throws {
        let app = XCUIApplication(bundleIdentifier: "com.taption.plan")
        // 부하가 큰 맥에서는 launch()가 프로세스를 못 잡고 실패해, 떠 있는 앱이 있으면 그 앱에 붙는다.
        if app.state == .notRunning { app.launchWithoutPrompts() } else { app.activate() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons["허용 안 함"]
        while decline.waitForExistence(timeout: 5) { decline.tap() }
        let skip = app.buttons["전체 건너뛰기"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        while decline.waitForExistence(timeout: 3) { decline.tap() }
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "메뉴")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        menu.tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "표시")).firstMatch.tap()
        let counters = app.buttons["카운터 메뉴 열기"]
        XCTAssertTrue(counters.waitForExistence(timeout: 5))
        counters.tap()
        let gear = app.buttons["연봉 카운터 설정"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()

        // 용돈 칸은 「연봉 · 시급 · 용돈」 가운데 용돈 탭 안에 있다(연봉 탭이 생긴 뒤).
        let allowanceTab = app.buttons["용돈"]
        XCTAssertTrue(allowanceTab.waitForExistence(timeout: 10), "설정 시트에 용돈 탭이 없다")
        allowanceTab.tap()
        let monthChoice = app.buttons["한 달"]
        XCTAssertTrue(monthChoice.waitForExistence(timeout: 5), "용돈 탭에 기간 선택이 없다")
        var tries = 0
        while !monthChoice.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(monthChoice.isHittable)
        monthChoice.tap()
        // 용돈 탭의 첫 입력 칸이 용돈이다.
        let field = app.textFields.firstMatch
        // 이전 값이 남아 있을 수 있어 비운다. 칸이 글자마다 쉼표를 다시 넣어 한 번에 지우면 숫자가 남는다.
        // 비면 회색 환산값(연봉이 없으면 0)이 보이므로, 지워도 값이 그대로면 다 지운 것이다.
        field.tap()
        tries = 0
        var previous: String?
        while tries < 20 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let current = field.value as? String
            if current == previous { break }
            previous = current
            tries += 1
        }
        field.typeText("300000")
        XCTAssertEqual(field.value as? String, "300,000")
        let days = Calendar.current.range(of: .day, in: .month, for: .now)!.count
        let monthly = Int((300_000.0 / Double(days * 24)).rounded())
        XCTAssertTrue(label(app, "환산 시급").waitForExistence(timeout: 5))
        XCTAssertTrue(label(app, "\(monthly)원").exists)
        capture("allowance-month")

        app.buttons["한 주"].tap()
        XCTAssertTrue(label(app, "1,786원").waitForExistence(timeout: 5), "30만 원 ÷ 168시간")
        capture("allowance-week")
        app.buttons["하루"].tap()
        XCTAssertTrue(label(app, "12,500원").waitForExistence(timeout: 5), "30만 원 ÷ 24시간")
        monthChoice.tap()

        // 설정 시트와 메뉴를 닫고 지도로 돌아간다.
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        sleep(2)
        capture("menu-after-sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        sleep(12)
        capture("counter-on-map")
        let row = label(app, "용돈")
        // 카운터 창은 지도 위 화랑이 머리 위에 선다. 자정 직후처럼 오늘 기록이 없어 화랑이가 없는 기기에서는
        // 창이 설 자리가 없으므로, 여기까지(입력·환산)만 확인하고 지도 줄은 건너뛴다(통과가 아니라 건너뜀으로 남는다).
        if !row.waitForExistence(timeout: 20) {
            try XCTSkipUnless(label(app, "현재 위치 · 활동").exists, "지도에 화랑이가 없어 카운터 창이 뜨지 않는 기기·시각 — 지도 용돈 줄은 확인하지 못함")
            XCTFail("화랑이는 있는데 지도 카운터에 용돈 줄이 없음")
        }
        row.tap()
        XCTAssertTrue(label(app, "24시간 내내").waitForExistence(timeout: 10), "용돈 줄을 눌러도 상세가 열리지 않음")
        capture("allowance-detail")
    }
}
