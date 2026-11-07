import XCTest

/// 언어 팩 화면을 돌며 스크린샷과 화면 글자를 남긴다. 검증자가 `LANGUAGE_PACK_OUT`을 줄 때만 돈다.
final class TaptionPlanLanguagePackUITests: XCTestCase {
    private var out = ""
    private var index = 0

    func testWalkMainScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LANGUAGE_PACK_OUT"],
              let language = environment["LANGUAGE_PACK_CODE"]
        else { throw XCTSkip("언어 지정 없음") }
        out = path + "/" + language
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))"]
        app.launch()
        // 지도 홈 메뉴나 첫 실행 튜토리얼이 뜰 때까지 기다린다.
        let firstScreen = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "메뉴", "firstRunNext")).firstMatch
        UITestWait.until(60) { firstScreen.exists && firstScreen.isHittable }
        UITestWait.settled(app)
        walkTutorial(app)
        capture(app, "home")

        let bar = app.windows.firstMatch
        func tapBottom(_ slot: Int) {
            bar.coordinate(withNormalizedOffset: CGVector(dx: (Double(slot) + 0.5) / 7.0 * 0.92 + 0.04, dy: 0.963)).tap()
            UITestWait.settled(app)
        }
        func dismiss() {
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            UITestWait.settled(app)
        }

        for (slot, name) in [(1, "calendar"), (6, "memo")] {
            tapBottom(slot)
            capture(app, name)
            dismiss()
        }

        tapBottom(0)
        capture(app, "menu-top")
        var labels: [String] = []
        for _ in 0..<4 {
            for label in app.buttons.allElementsBoundBy_labels() where !labels.contains(label) && isInMenu(app, label) {
                labels.append(label)
            }
            bar.swipeUp()
            UITestWait.settled(app)
        }
        dismiss()
        for (position, label) in labels.prefix(40).enumerated() {
            tapBottom(0)
            var button = app.buttons[label].firstMatch
            var swipes = 0
            while !(button.exists && button.isHittable), swipes < 4 {
                bar.swipeUp()
                UITestWait.settled(app)
                button = app.buttons[label].firstMatch
                swipes += 1
            }
            guard button.exists, button.isHittable else {
                dismiss()
                continue
            }
            button.tap()
            UITestWait.settled(app)
            capture(app, "menu-\(position)")
            app.swipeUp()
            UITestWait.settled(app)
            capture(app, "menu-\(position)-down")
            dismiss()
            dismiss()
        }
    }

    /// 새로 설치한 기기라면 첫 실행 튜토리얼을 넘기며 남긴다.
    private func walkTutorial(_ app: XCUIApplication) {
        let next = app.descendants(matching: .any).matching(identifier: "firstRunNext").firstMatch
        var step = 0
        while next.exists, next.isHittable, step < 16 {
            capture(app, "tutorial-\(step)")
            next.tap()
            UITestWait.settled(app)
            step += 1
        }
    }

    /// 메뉴 시트 안의 버튼만 고른다. 지도 위 버튼과 닫기는 빼고, 지우기처럼 되돌릴 수 없는 행은 시험 대상이 아니다.
    private func isInMenu(_ app: XCUIApplication, _ label: String) -> Bool {
        let frame = app.buttons[label].firstMatch.frame
        let window = app.windows.firstMatch.frame
        return frame.minX < window.width * 0.2 && frame.width > window.width * 0.4 && frame.minY > window.height * 0.15
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        index += 1
        let stem = String(format: "%@/%02d-%@", out, index, name)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: stem + ".png"))
        try? app.debugDescription.write(toFile: stem + ".txt", atomically: true, encoding: .utf8)
    }
}

private extension XCUIElementQuery {
    func allElementsBoundBy_labels() -> [String] {
        var seen = Set<String>()
        return allElementsBoundByIndex.compactMap { element in
            let label = element.label
            guard !label.isEmpty, seen.insert(label).inserted else { return nil }
            return label
        }
    }
}
