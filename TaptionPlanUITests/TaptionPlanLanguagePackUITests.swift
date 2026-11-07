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
        // 지도 홈(날짜 배지)이나 첫 실행 튜토리얼이 뜰 때까지 기다린다. 메뉴 이름은 언어마다 달라 식별자로 찾는다.
        let home = app.descendants(matching: .any)["mapHomeDateBadge"].firstMatch
        let firstScreen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["mapHomeDateBadge", "firstRunNext"])).firstMatch
        UITestWait.until(60) { firstScreen.exists && firstScreen.isHittable }
        UITestWait.settled(app)
        walkTutorial(app)
        XCTAssertTrue(UITestWait.reachMapHome(app, menu: home), "지도 홈에 닿지 못함")
        UITestWait.settled(app)
        capture(app, "home")

        let bar = app.windows.firstMatch
        let origin = bar.coordinate(withNormalizedOffset: .zero)
        let widePanel = app.descendants(matching: .any)["mapHomeWidePanel"].firstMatch
        // 하단 메뉴 알약: 좌우·아래 여백 14pt, 높이 56pt. 넓은 화면(600pt 이상)은 왼쪽 아래 402pt 폭이다.
        func tapBottom(_ slot: Int) {
            let window = bar.frame
            let barWidth = window.width >= 600 ? 402 : window.width - 28
            origin.withOffset(CGVector(dx: 14 + (Double(slot) + 0.5) / 7.0 * barWidth, dy: window.height - 14 - 28)).tap()
            UITestWait.settled(app)
        }
        // 메뉴 서랍과 넓은 화면의 왼쪽 패널은 끌어 내려도 닫히지 않는다. 보이는 닫기(×) 단추를 먼저 누른다.
        func dismiss() {
            let close = app.buttons.matching(identifier: "xmark").allElementsBoundByIndex.last { $0.isHittable }
            if let close {
                close.tap()
            } else if widePanel.exists {
                let frame = widePanel.frame
                origin.withOffset(CGVector(dx: frame.maxX - 30, dy: frame.minY + 30)).tap()
            } else {
                bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            }
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
            // 메뉴 서랍은 앞서 내려 둔 스크롤 자리를 기억한다. 맨 위로 올린 뒤 아래로 찾는다.
            for _ in 0..<4 { bar.swipeDown() }
            UITestWait.settled(app)
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
            // 권한 줄은 설정 앱을 연다. 넘어가는 중에 앱 트리를 읽으면 시험이 깨지므로 잠깐 지켜본 뒤 앱으로 돌아와 다음 줄로 간다.
            if UITestWait.until(1.5, { app.state != .runningForeground }) {
                app.activate()
                UITestWait.until(10) { app.state == .runningForeground }
                UITestWait.settled(app)
                dismiss()
                continue
            }
            UITestWait.settled(app)
            if UITestWait.declineSystemAlert() { UITestWait.settled(app) }
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
        while next.exists, next.isHittable, step < 24 {
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
