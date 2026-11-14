import XCTest
@testable import TaptionRules

final class RuleEngineTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Bad: Decodable { let why: String; let rule: Rule }
        let valid: [Rule]
        let invalid: [Bad]
    }

    /// 서버 시험과 같은 견본 파일을 읽는다. 두 쪽의 모양 검사가 어긋나면 여기서 드러난다.
    private func fixtures() throws -> Fixtures {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("server/trip-relay/test/fixtures/rules.json"))
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }

    func testSharedFixturesAgreeWithTheServer() throws {
        let fixtures = try fixtures()
        XCTAssertEqual(Set(fixtures.valid.map(\.type)), Set(RuleType.allCases.map(\.rawValue)), "every rule type has a valid example")
        for rule in fixtures.valid { XCTAssertTrue(RuleShape.isValid(rule), rule.type) }
        for bad in fixtures.invalid { XCTAssertFalse(RuleShape.isValid(bad.rule), bad.why) }
        XCTAssertTrue(RuleShape.isSafePattern(#"(?<amount>[\d,]+)원"#))
        XCTAssertFalse(RuleShape.isSafePattern(String(repeating: "x", count: 301)))
    }

    private func rule(_ id: String, _ type: RuleType, _ match: [String: RuleValue], _ result: [String: RuleValue] = [:], by: String = "ai", at: String = "2026-11-14T00:00:00Z",
                      enabled: Bool = true, appliesTo: Int = 1) -> Rule {
        Rule(id: id, type: type.rawValue, appliesTo: appliesTo, enabled: enabled, match: match, result: result, source: .init(by: by), updatedAt: at)
    }

    func testUsableSkipsWhatThisAppCannotReadAndPutsUserRulesFirst() {
        let set = RuleSet(version: 7, rules: [
            rule("old", .merchantCategory, ["contains": .list(["빵집"])], ["category": .text("cafe")], at: "2026-11-01T00:00:00Z"),
            rule("new", .merchantCategory, ["contains": .list(["빵집"])], ["category": .text("food")], at: "2026-11-10T00:00:00Z"),
            rule("mine", .merchantCategory, ["equals": .text("빵집 본점")], ["category": .text("gift")], by: "user", at: "2026-10-01T00:00:00Z"),
            rule("off", .skipWord, ["word": .text("광고")], enabled: false),
            rule("future", .skipWord, ["word": .text("이벤트")], appliesTo: 2),
            Rule(id: "unknown", type: "teleport", match: [:]),
            rule("broken", .merchantCategory, ["contains": .list(["빵집"])], ["category": .text("fun")]),
        ])
        let (rules, skipped) = RuleEngine.usable(set)
        XCTAssertEqual(rules.map(\.id), ["mine", "new", "old"])
        XCTAssertEqual(skipped.sorted(), ["broken", "future", "unknown"], "a disabled rule is not reported as skipped")
        XCTAssertEqual(RuleEngine.merchantCategory(merchant: "빵집 본점", rules: rules)?.category, "gift", "the user's rule wins")
        XCTAssertEqual(RuleEngine.merchantCategory(merchant: "동네 빵집", rules: rules)?.category, "food", "then the newest AI rule")
        XCTAssertNil(RuleEngine.merchantCategory(merchant: "국수집", rules: rules))
    }

    func testPaymentTextHelpers() {
        let rules = [
            rule("skip", .skipWord, ["word": .text("광고")]),
            rule("notice", .textIgnore, ["contains": .list(["혜택 안내", "할인받은 금액"])], ["reason": .text("통신사 안내")]),
            rule("bank", .textIgnore, ["contains": .list(["점검 안내"]), "source": .text("은행앱")]),
            rule("topup", .internalTransfer, ["contains": .list(["지역카드", "충전"])]),
            rule("acct", .ownAccount, ["name": .text("생활비통장")]),
            rule("app", .sourceSwitch, ["app": .text("은행앱")], ["expense": .flag(true), "income": .flag(false)]),
            rule("card", .paymentText, ["pattern": .text(#"(?<merchant>.+) (?<amount>[\d,]+)원 승인"#), "sample": .text("가게 12,000원 승인")], ["kind": .text("expense"), "name": .text("카드")]),
        ]
        XCTAssertEqual(RuleEngine.skipWord(in: "[광고] 오늘만 할인", rules: rules)?.id, "skip")
        XCTAssertNil(RuleEngine.skipWord(in: "가게 12,000원 승인", rules: rules))
        XCTAssertEqual(RuleEngine.textIgnore("11월 혜택 안내: 할인받은 금액 31,733원", rules: rules)?.id, "notice")
        XCTAssertNil(RuleEngine.textIgnore("혜택 안내만 있는 글", rules: rules), "every word must be there")
        XCTAssertNil(RuleEngine.textIgnore("시스템 점검 안내", source: "다른앱", rules: rules))
        XCTAssertEqual(RuleEngine.textIgnore("시스템 점검 안내", source: "은행앱", rules: rules)?.id, "bank")
        XCTAssertEqual(RuleEngine.internalTransfer("지역카드 30,000원 충전 완료", rules: rules)?.id, "topup")
        XCTAssertEqual(RuleEngine.ownAccountNames(rules: rules), ["생활비통장"])
        let lane = RuleEngine.sourceSwitch(app: "은행앱", rules: rules)
        XCTAssertEqual([lane?.expense, lane?.income], [true, false])
        XCTAssertEqual(RuleEngine.paymentTextRules(rules: rules).map(\.kind), ["expense"])
    }

    func testReceiptCalendarAndRideHelpers() {
        let rules = [
            rule("bill", .receiptHint, ["contains": .list(["진료비 계산서"])], ["isReceipt": .flag(true), "category": .text("health")]),
            rule("shot", .receiptHint, ["contains": .list(["필터 추가", "알림"])], ["isReceipt": .flag(false)]),
            rule("meet", .calendarTitle, ["title": .text("주간 회의")], ["detailId": .text("work.meeting")]),
            rule("bday", .calendarTitle, ["title": .text("생일")], ["detailId": .text("none")]),
            rule("pair", .placePairMode, ["from": .text("집"), "to": .text("회사")], ["mode": .text("bus"), "line": .text("80")]),
            rule("ride", .rideLine, ["board": .text("가 정류소"), "alight": .text("나 정류소"), "mode": .text("bus")], ["line": .text("80")]),
        ]
        let bill = RuleEngine.receiptHint("진료비 계산서 · 영수증\n합계 10,000", rules: rules)
        XCTAssertEqual(bill?.isReceipt, true)
        XCTAssertEqual(bill?.category, "health")
        XCTAssertEqual(RuleEngine.receiptHint("앱에서 알림을 수신할 때 필터 추가", rules: rules)?.isReceipt, false)
        XCTAssertNil(RuleEngine.receiptHint("그냥 사진", rules: rules))
        XCTAssertEqual(RuleEngine.calendarTitle(" 주간 회의 ", rules: rules)?.detailID, "work.meeting")
        let birthday = RuleEngine.calendarTitle("생일", rules: rules)
        XCTAssertNotNil(birthday)
        XCTAssertNil(birthday?.detailID, "none means: do not classify")
        XCTAssertEqual(RuleEngine.placePairMode(from: "집", to: "회사", rules: rules)?.line, "80")
        XCTAssertNil(RuleEngine.placePairMode(from: "회사", to: "집", rules: rules), "direction matters")
        XCTAssertEqual(RuleEngine.rideLine(board: "가 정류소", alight: "나 정류소", mode: "bus", rules: rules)?.line, "80")
        XCTAssertNil(RuleEngine.rideLine(board: "가 정류소", alight: "나 정류소", mode: "subway", rules: rules))
    }

    func testRuleSetDecodesTheServerShapeAndSurvivesUnknownFields() throws {
        let json = #"{"format":"bokki-rules","version":3,"engine":1,"rules":[{"id":"r_1","type":"merchant_category","appliesTo":1,"enabled":true,"match":{"contains":["빵집"]},"result":{"category":"cafe"},"source":{"by":"ai","keyId":"ab12cd34"},"createdAt":"2026-11-14T00:00:00.000Z","updatedAt":"2026-11-14T00:00:00.000Z"},{"id":"r_2","type":"later","appliesTo":3,"enabled":true,"match":{"deep":{"a":1}},"result":{}}],"app":null}"#
        let set = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertEqual(set.version, 3)
        XCTAssertEqual(set.rules.map(\.id), ["r_1", "r_2"])
        XCTAssertEqual(RuleEngine.usable(set).skipped, ["r_2"], "a rule from a newer server is kept and skipped, not dropped")
    }
}
