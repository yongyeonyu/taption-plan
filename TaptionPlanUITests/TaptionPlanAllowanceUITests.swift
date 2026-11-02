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
        if app.state == .notRunning { app.launch() } else { app.activate() }
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

        let monthChoice = app.buttons["한 달"]
        var tries = 0
        while !monthChoice.isHittable && tries < 5 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(monthChoice.isHittable)
        monthChoice.tap()
        // 연봉 입력 세 칸 다음이 용돈 칸이다.
        let field = app.textFields.element(boundBy: 3)
        // 이전 값이 남아 있을 수 있어 비운다. 칸이 글자마다 쉼표를 다시 넣어 한 번에 지우면 숫자가 남는다.
        field.tap()
        tries = 0
        while (field.value as? String) != "0", tries < 20 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
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
        XCTAssertTrue(row.waitForExistence(timeout: 20), "지도 카운터에 용돈 줄이 없음")
        row.tap()
        XCTAssertTrue(label(app, "24시간 내내").waitForExistence(timeout: 10), "용돈 줄을 눌러도 상세가 열리지 않음")
        capture("allowance-detail")
    }
}
