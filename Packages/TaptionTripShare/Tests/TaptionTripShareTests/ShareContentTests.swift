import Foundation
import XCTest
@testable import TaptionTripShare

/// 암호화 전 평문 모델과 정산 계산. 이름·금액은 모두 지어낸 값이다.
final class ShareContentTests: XCTestCase {
    private func roundTrip(_ content: ShareContent) throws -> ShareContent {
        try ShareContent.decode(kind: content.kind, json: ShareCipher.padded(try content.json()))
    }

    private func keys(_ content: ShareContent) throws -> Set<String> {
        Set(try XCTUnwrap(JSONSerialization.jsonObject(with: content.json()) as? [String: Any]).keys)
    }

    func testEveryKindRoundTripsThroughPaddedJSON() throws {
        let contents: [ShareContent] = [
            .plan(SharePlanContent(day: "2031-05-06", start: 540, end: 600, startOffset: 540, endOffset: 540, title: "아침 산책", place: "가상의 공원",
                                   memo: "편한 신발", cost: 12_000, currency: "KRW", order: 2, planKind: "walk", status: "planned", colorHex: "#3366FF",
                                   parentItemID: "QEFCQ0RFRkdISUpLTE1OTw", by: 1)),
            .sharedExpense(ShareExpenseContent(title: "점심", amount: 3_000, currency: "JPY", amountKRW: 27_500, payer: .member(1),
                                               split: [.member(1), .member(2), .guest(1)], category: "food", memo: "셋이서", at: 1_900_000_000_000, by: 1)),
            .ownExpense(ShareOwnExpenseContent(amount: 5_000, currency: "KRW", category: "gift", memo: nil, at: 1_900_000_000_000, by: 2)),
            .notice(ShareNoticeContent(text: "세 시까지 모여요", important: true, createdAt: 1_900_000_000_000, due: 1_900_000_600_000, place: "가상의 광장", by: 1)),
            .member(ShareMemberCard(name: "가을", color: "#FF8800", sent: ["m2>m1:KRW:5000"])),
            .meta(ShareTripMeta(name: "봄 여행", startDay: "2031-05-05", endDay: "2031-05-09", currency: "KRW", budget: 800_000,
                                guests: [ShareGuest(id: 1, name: "솔")], settlementOff: false, country: "가상국", region: "가상도",
                                timeZone: "Asia/Seoul", columns: ["time", "title", "cost"], shareAllExpenses: true)),
            .meet(ShareMeetContent(name: "가상의 광장", latitude: 10.5, longitude: 20.5, at: 1_900_000_600_000, by: 1)),
        ]
        XCTAssertEqual(contents.map(\.kind), ShareKind.allCases.map(\.rawValue))
        for content in contents {
            XCTAssertEqual(try roundTrip(content), content)
            XCTAssertEqual(content.version, 1)
            XCTAssertFalse(content.isReadOnly)
            XCTAssertEqual(try content.json(), try content.json(), "같은 내용이면 같은 글자")
        }
    }

    func testOptionalFieldsAreOptional() throws {
        XCTAssertEqual(try ShareContent.decode(kind: "plan", json: Data(#"{"v":1,"day":"2031-05-06","title":"t"}"#.utf8)),
                       .plan(SharePlanContent(day: "2031-05-06", title: "t")))
        XCTAssertEqual(try ShareContent.decode(kind: "expense-shared", json: Data(#"{"v":1,"amount":10,"currency":"KRW","payer":"m1","split":["m1","g2"],"at":5}"#.utf8)),
                       .sharedExpense(ShareExpenseContent(amount: 10, currency: "KRW", payer: .member(1), split: [.member(1), .guest(2)], at: 5)))
        XCTAssertEqual(try ShareContent.decode(kind: "notice", json: Data(#"{"v":1,"text":"n","important":false,"createdAt":5}"#.utf8)),
                       .notice(ShareNoticeContent(text: "n", createdAt: 5)))
        XCTAssertEqual(try ShareContent.decode(kind: "meta", json: Data(#"{"v":1,"name":"n","startDay":"a","endDay":"b","currency":"KRW","guests":[]}"#.utf8)),
                       .meta(ShareTripMeta(name: "n", startDay: "a", endDay: "b", currency: "KRW")))
    }

    func testPlanEndMayPassMidnight() throws {
        // 수면·야간 이동: 23:00에 시작해 다음 날 07:30에 끝난다(1,440분을 넘는 끝).
        let plan = SharePlanContent(day: "2031-05-06", start: 1_380, end: 1_890, startOffset: 540, endOffset: 480, title: "야간 이동")
        guard case .plan(let back) = try roundTrip(.plan(plan)) else { return XCTFail() }
        XCTAssertEqual(back.end, 1_890)
        XCTAssertGreaterThan(try XCTUnwrap(back.end), 1_440)
        XCTAssertEqual(back.endOffset, 480)
    }

    func testNoCoordinatesAnywhere() throws {
        let all: [ShareContent] = [
            .plan(SharePlanContent(day: "d", title: "t", place: "p")),
            .sharedExpense(ShareExpenseContent(amount: 1, currency: "KRW", payer: .member(1), split: [.member(1)], at: 1)),
            .ownExpense(ShareOwnExpenseContent(amount: 1, currency: "KRW", at: 1)),
            .notice(ShareNoticeContent(text: "t", createdAt: 1, place: "p")),
            .member(ShareMemberCard(name: "n", color: "c")),
            .meta(ShareTripMeta(name: "n", startDay: "a", endDay: "b", currency: "KRW")),
        ]
        for content in all {
            for key in try keys(content) {
                let lowered = key.lowercased()
                XCTAssertFalse(["lat", "lon", "lng", "coord", "geo"].contains(where: lowered.contains), "\(content.kind).\(key)")
            }
        }
    }

    func testHiddenOwnExpenseIsNeverContent() {
        let expense = ShareOwnExpenseContent(amount: 9_000, currency: "KRW", at: 1)
        XCTAssertNil(ShareContent.ownExpense(expense, visibility: .hidden), "비공개는 방에 올릴 내용이 없다")
        XCTAssertEqual(ShareContent.ownExpense(expense, visibility: .open), .ownExpense(expense))
        XCTAssertEqual(ShareContent.ownExpense(expense, visibility: .open)?.kind, "expense-own")
    }

    func testHigherVersionIsReadOnly() throws {
        // 같은 모양에 모르는 칸이 더 있으면 읽되 「읽기만」.
        let readable = try ShareContent.decode(kind: "plan", json: Data(#"{"v":2,"day":"2031-05-06","title":"t","future":[1,2]}"#.utf8))
        guard case .plan(let plan) = readable else { return XCTFail() }
        XCTAssertEqual(plan.title, "t")
        XCTAssertEqual(readable.version, 2)
        XCTAssertTrue(readable.isReadOnly)
        // 모양이 달라져 읽지 못하면 내용 없이 표시만.
        let opaque = try ShareContent.decode(kind: "plan", json: Data(#"{"v":3,"when":{"day":1}}"#.utf8))
        XCTAssertEqual(opaque, .unsupported(kind: "plan", version: 3))
        XCTAssertTrue(opaque.isReadOnly)
        XCTAssertThrowsError(try opaque.json())
        // 이 판의 모양이 아닌 v1, 버전 칸이 없는 것은 버린다.
        XCTAssertThrowsError(try ShareContent.decode(kind: "plan", json: Data(#"{"v":1,"when":1}"#.utf8)))
        XCTAssertThrowsError(try ShareContent.decode(kind: "plan", json: Data(#"{"day":"d","title":"t"}"#.utf8)))
        XCTAssertThrowsError(try ShareContent.decode(kind: "plan", json: Data("[]".utf8)))
    }

    func testPartyCodesAndOrder() throws {
        XCTAssertEqual([ShareParty.guest(1), .member(10), .member(2), .guest(3)].sorted(), [.member(2), .member(10), .guest(1), .guest(3)])
        XCTAssertEqual(ShareParty(code: "m12"), .member(12))
        XCTAssertEqual(ShareParty(code: "g3"), .guest(3))
        for bad in ["", "m", "x1", "m0", "m-1", "g1a"] { XCTAssertNil(ShareParty(code: bad), bad) }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([ShareParty.member(1), .guest(2)]), as: UTF8.self), #"["m1","g2"]"#)
    }

    // MARK: 정산

    private func entry(_ id: String, _ amount: Int, payer: ShareParty, split: [ShareParty], currency: String = "KRW", krw: Int? = nil) -> ShareSettlementEntry {
        ShareSettlementEntry(id: id, expense: ShareExpenseContent(amount: amount, currency: currency, amountKRW: krw, payer: payer, split: split, at: 1))
    }

    private let a = ShareParty.member(1), b = ShareParty.member(2), c = ShareParty.member(3), guest = ShareParty.guest(1)

    func testSettlementSplitsAndFindsTransfers() throws {
        let result = ShareSettlementCalculator.settle([
            entry("exp-0001", 30_000, payer: a, split: [a, b, c]),
            entry("exp-0002", 12_000, payer: b, split: [a, b, guest]),
        ], parties: [a, b, c, guest])
        XCTAssertEqual(result.count, 1)
        let settlement = try XCTUnwrap(result.first)
        XCTAssertEqual(settlement.currency, "KRW")
        XCTAssertEqual(settlement.balances.map(\.party), [a, b, c, guest])
        XCTAssertEqual(settlement.balances.map(\.paid), [30_000, 12_000, 0, 0])
        XCTAssertEqual(settlement.balances.map(\.owed), [14_000, 14_000, 10_000, 4_000])
        XCTAssertEqual(settlement.balances.map(\.net), [16_000, -2_000, -10_000, -4_000])
        XCTAssertEqual(settlement.balances.map(\.net).reduce(0, +), 0)
        XCTAssertEqual(settlement.transfers, [
            ShareTransfer(from: c, to: a, amount: 10_000, currency: "KRW"),
            ShareTransfer(from: guest, to: a, amount: 4_000, currency: "KRW"),
            ShareTransfer(from: b, to: a, amount: 2_000, currency: "KRW"),
        ])
        XCTAssertEqual(settlement.transfers[0].key, "m3>m1:KRW:10000")
    }

    func testRemainderGoesOneWonEachInPartyOrder() {
        // 10,000원을 셋이: 3,333씩, 나머지 1원은 사람 순으로 맨 앞(참여자 1).
        XCTAssertEqual(ShareSettlementCalculator.shares(of: 10_000, payer: c, split: [c, b, a]).map(\.share), [3_334, 3_333, 3_333])
        // 나머지 2원: 앞의 두 사람. 참여자가 앱 없는 일행보다 앞선다. 겹쳐 적은 사람은 한 번만 센다.
        let shares = ShareSettlementCalculator.shares(of: 11, payer: a, split: [guest, b, a, b])
        XCTAssertEqual(shares.map(\.party), [a, b, guest])
        XCTAssertEqual(shares.map(\.share), [4, 4, 3])
        XCTAssertEqual(shares.map(\.share).reduce(0, +), 11)
        // 낸 사람이 나눌 사람에 없어도 같은 규칙.
        XCTAssertEqual(ShareSettlementCalculator.shares(of: 5, payer: a, split: [b, c]).map(\.share), [3, 2])
    }

    func testEmptySplitIsThePayerAloneNotWhoeverIsHereNow() throws {
        // 「비면 모두」로 읽지 않는다: 나중에 들어온 사람에게 몫이 생기지 않는다.
        let entries = [entry("exp-0001", 9_000, payer: a, split: [])]
        let before = ShareSettlementCalculator.settle(entries, parties: [a, b])
        let after = ShareSettlementCalculator.settle(entries, parties: [a, b, c])
        XCTAssertEqual(before.first?.balances.first, ShareBalance(party: a, paid: 9_000, owed: 9_000))
        XCTAssertEqual(before.first?.transfers, [])
        XCTAssertEqual(after.first?.balances.filter { $0.net != 0 }, [])
    }

    func testSettlementIsTheSameOnEveryDevice() {
        var entries = (1...9).map { index in
            entry(String(format: "exp-%04d", index), 1_000 * index + index, payer: [a, b, c][index % 3], split: index % 2 == 0 ? [a, b, c] : [b, guest, a])
        }
        let expected = ShareSettlementCalculator.settle(entries, parties: [a, b, c, guest])
        for _ in 0..<5 {
            entries.shuffle()
            XCTAssertEqual(ShareSettlementCalculator.settle(entries, parties: [guest, c, b, a].shuffled()), expected)
        }
        XCTAssertEqual(expected.first?.balances.map(\.net).reduce(0, +), 0)
        XCTAssertLessThanOrEqual(expected.first?.transfers.count ?? 9, 3)
    }

    func testSettlementUsesTheWonAmountSavedAtEntry() throws {
        let result = ShareSettlementCalculator.settle([
            entry("exp-0001", 3_000, payer: a, split: [a, b], currency: "JPY", krw: 27_001),
            entry("exp-0002", 10_000, payer: b, split: [a, b]),
            entry("exp-0003", 40, payer: a, split: [a, b], currency: "USD"), // 환산이 없으면 그 통화로 따로.
        ], parties: [a, b])
        XCTAssertEqual(result.map(\.currency), ["KRW", "USD"])
        let won = try XCTUnwrap(result.first)
        XCTAssertEqual(won.balances.map(\.paid), [27_001, 10_000])
        XCTAssertEqual(won.balances.map(\.owed), [13_501 + 5_000, 13_500 + 5_000])
        XCTAssertEqual(won.transfers, [ShareTransfer(from: b, to: a, amount: 8_500, currency: "KRW")])
        XCTAssertEqual(result[1].transfers, [ShareTransfer(from: b, to: a, amount: 20, currency: "USD")])
    }

    func testSettlementIgnoresNonPositiveAndKeepsPeopleWhoLeft() throws {
        let gone = ShareParty.member(7)
        let result = ShareSettlementCalculator.settle([
            entry("exp-0001", 0, payer: a, split: [a, b]),
            entry("exp-0002", -500, payer: a, split: [a, b]),
            entry("exp-0003", 6_000, payer: gone, split: [a, gone]),
        ], parties: [a, b])
        let settlement = try XCTUnwrap(result.first)
        XCTAssertEqual(settlement.balances.map(\.party), [a, b, gone])
        XCTAssertEqual(settlement.balances.map(\.net), [-3_000, 0, 3_000])
        XCTAssertEqual(settlement.transfers, [ShareTransfer(from: a, to: gone, amount: 3_000, currency: "KRW")])
        XCTAssertEqual(ShareSettlementCalculator.settle([], parties: [a, b]), [])
    }

    /// 터무니없이 큰 금액 두 건이 합계를 넘치게 해 모든 기기를 멈추게 하지 못한다(REV1117A01).
    func testAbsurdAmountsAreIgnoredInsteadOfOverflowing() throws {
        let result = ShareSettlementCalculator.settle([
            entry("exp-0001", Int.max / 2, payer: a, split: [a, b]),
            entry("exp-0002", Int.max / 2, payer: a, split: [a, b]),
            entry("exp-0003", ShareSettlementCalculator.maxAmount, payer: a, split: [a, b]),
            entry("exp-0004", ShareSettlementCalculator.maxAmount + 1, payer: b, split: [a, b]),
        ], parties: [a, b])
        let settlement = try XCTUnwrap(result.first)
        XCTAssertEqual(settlement.balances.map(\.paid), [ShareSettlementCalculator.maxAmount, 0])
    }
}
