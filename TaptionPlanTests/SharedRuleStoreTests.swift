import CryptoKit
import XCTest
@testable import TaptionPlan

/// 공통 규칙(SRL1116A01): 서명 확인, 끄기, 우선순위, 올리기 전 거르기.
@MainActor
final class SharedRuleStoreTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }

    private func defaults() -> UserDefaults {
        let name = "SharedRuleStoreTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return store
    }

    private func bundle(_ version: Int, rules: String, signedBy key: Curve25519.Signing.PrivateKey? = nil) throws -> SharedRuleStore.SignedBundle {
        let payload = #"{"format":"bokki-shared-rules","version":\#(version),"engine":1,"issuedAt":"2026-11-16","rules":[\#(rules)]}"#
        let signature = try (key ?? signer).signature(for: Data(payload.utf8)).base64EncodedString()
        return .init(version: version, payload: payload, signature: signature)
    }

    private let cafe = #"{"id":"s_cafe","type":"merchant_category","match":{"contains":["스타벅스"]},"result":{"category":"cafe"}}"#
    private let card = #"{"id":"s_card","type":"payment_text","match":{"pattern":"(?<merchant>.+) (?<amount>[\\d,]+)원 승인","sample":"가게 12,000원 승인"},"result":{"kind":"expense","name":"카드"}}"#
    private let skipSwitch = #"{"id":"s_own","type":"own_account","match":{"name":"비상금"},"result":{}}"#

    private func save(_ bundle: SharedRuleStore.SignedBundle, _ store: UserDefaults) {
        store.set(try? JSONEncoder().encode(bundle), forKey: SharedRuleStore.bundleKey)
    }

    func testOnlyASignedBundleIsUsedAndPersonalTypesAreDropped() throws {
        let good = try bundle(3, rules: [cafe, card, skipSwitch].joined(separator: ","))
        XCTAssertEqual(SharedRuleStore.rules(in: good, publicKey: publicKey).map(\.id), ["s_cafe", "s_card"], "own_account is not a shared type")
        XCTAssertEqual(SharedRuleStore.rules(in: good, publicKey: publicKey).first?.source?.by, "shared")
        XCTAssertTrue(SharedRuleStore.rules(in: good, publicKey: nil).isEmpty, "no public key, no shared rules")
        XCTAssertTrue(SharedRuleStore.rules(in: good, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()).isEmpty, "another key")
        var tampered = good
        tampered.payload = good.payload.replacingOccurrences(of: "cafe", with: "food")
        XCTAssertTrue(SharedRuleStore.rules(in: tampered, publicKey: publicKey).isEmpty, "a changed payload fails the signature")
        var renumbered = good
        renumbered.version = 9
        XCTAssertTrue(SharedRuleStore.rules(in: renumbered, publicKey: publicKey).isEmpty, "the version must match the signed payload")
        let futureEngine = try bundle(4, rules: cafe).payload.replacingOccurrences(of: #""engine":1"#, with: #""engine":2"#)
        let signed = SharedRuleStore.SignedBundle(version: 4, payload: futureEngine, signature: try signer.signature(for: Data(futureEngine.utf8)).base64EncodedString())
        XCTAssertTrue(SharedRuleStore.rules(in: signed, publicKey: publicKey).isEmpty, "a newer engine than this app reads")
    }

    func testSwitchesAndPerRuleOffAndPaymentRules() throws {
        let store = defaults()
        save(try bundle(1, rules: [cafe, card].joined(separator: ",")), store)
        XCTAssertEqual(SharedRuleStore.active(store, publicKey: publicKey).map(\.id), ["s_cafe", "s_card"])
        XCTAssertEqual(SharedRuleStore.paymentRules(store, publicKey: publicKey).count, 1)
        SharedRuleStore.setEnabled("s_cafe", false, defaults: store)
        XCTAssertEqual(SharedRuleStore.active(store, publicKey: publicKey).map(\.id), ["s_card"])
        XCTAssertEqual(SharedRuleStore.all(store, publicKey: publicKey).count, 2, "a switched-off rule stays listed")
        store.set(false, forKey: SharedRuleStore.receiveKey)
        XCTAssertTrue(SharedRuleStore.active(store, publicKey: publicKey).isEmpty)
        XCTAssertTrue(SharedRuleStore.paymentRules(store, publicKey: publicKey).isEmpty)
        XCTAssertTrue(SharedRuleStore.isReceiving(defaults()), "receiving is on by default")
        XCTAssertFalse(SharedRuleStore.isContributing(defaults()), "contributing is off by default")
    }

    func testSharedPaymentRuleReadsATextAfterTheDevicesOwnRules() throws {
        let store = defaults()
        save(try bundle(1, rules: card), store)
        let shared = SharedRuleStore.paymentRules(store, publicKey: publicKey)
        let text = "동네가게 12,000원 승인"
        guard case let .draft(draft, income)? = LedgerMessageRules.match(text, defaults: store, shared: shared) else { return XCTFail("shared rule did not read the text") }
        XCTAssertEqual(draft.amount, 12_000)
        XCTAssertFalse(income)
        XCTAssertNil(LedgerMessageRules.match(text, defaults: store), "without the shared rule nothing reads it")
    }

    /// REV1117A02: 저장할 판 번호는 서명한 글 안의 것과 같아야 한다(겉 번호만 키운 예전 묶음이 새 판을 막지 못하게).
    func testTheStoredVersionComesFromTheSignedPayload() throws {
        var renumbered = try bundle(3, rules: cafe)
        renumbered.version = Int.max
        XCTAssertEqual(SharedRuleStore.signedVersion(renumbered), 3)
        XCTAssertEqual(SharedRuleStore.signedVersion(try bundle(4, rules: cafe)), 4)
        XCTAssertNil(SharedRuleStore.signedVersion(.init(version: 1, payload: "not json", signature: "")))
    }

    func testOnlyFilteredAIRulesAreOfferedAndOnlyOnce() {
        let ai = Rule.Source(by: "ai")
        let rules = [
            Rule(id: "a", type: "merchant_category", match: ["contains": .list(["빵집"])], result: ["category": .text("cafe"), "title": .text("동네빵집")], source: ai),
            Rule(id: "b", type: "merchant_category", match: ["contains": .list(["홍길동님"])], result: ["category": .text("food")], source: ai),
            Rule(id: "c", type: "own_account", match: ["name": .text("비상금")], source: ai),
            Rule(id: "d", type: "merchant_category", match: ["contains": .list(["카페"])], result: ["category": .text("cafe")], source: .init(by: "user")),
            Rule(id: "e", type: "merchant_category", match: ["contains": .list(["빵집"])], result: ["category": .text("cafe")], source: ai),
        ]
        let first = SharedRuleStore.pending(rules: rules, sent: [])
        XCTAssertEqual(first.count, 1, "a name, a personal type, a user's own rule are refused and a duplicate counts once")
        XCTAssertNil(first[0].upload.result["title"], "the shop title is dropped")
        XCTAssertTrue(SharedRuleStore.pending(rules: rules, sent: Set(first.map(\.mark))).isEmpty)
    }

    /// HOF1118A01: 공통 규칙의 「결제가 아닌 글」이 내 결제 문자 정규식보다 먼저 적용되지 않는다.
    func testMyPaymentRegexComesBeforeASharedTextIgnore() throws {
        let store = defaults()
        let text = "[OO카드] 승인 12,300원 동네카페"
        guard case let .success(mine) = LedgerMessageRules.validated(name: "OO카드", pattern: #"\[OO카드\] 승인 (?<amount>[\d,]+)원 (?<merchant>.+)"#, sample: text, kind: .expense)
        else { return XCTFail("rule") }
        LedgerMessageRules.add(mine, defaults: store)
        let sharedIgnore = Rule(id: "s_ignore", type: "text_ignore", match: ["contains": .list(["승인"])], source: .init(by: "shared"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func verdict(_ text: String, _ rules: [Rule]) -> PaymentTextCapture.RuleVerdict {
            PaymentTextCapture.ruleVerdict(text, source: nil, rules: rules, now: now, defaults: store, sharedPayment: [])
        }

        guard case let .matched(.draft(draft, income)) = verdict(text, [sharedIgnore]) else { return XCTFail("\(verdict(text, [sharedIgnore]))") }
        XCTAssertEqual(draft.amount, 12_300)
        XCTAssertFalse(income)
        // 내 규칙의 「결제가 아닌 글」은 여전히 먼저다.
        let myIgnore = Rule(id: "u_ignore", type: "text_ignore", match: ["contains": .list(["승인"])], source: .init(by: "user"))
        XCTAssertEqual(verdict(text, [myIgnore]), .ignored)
        // 내 정규식이 읽지 못하는 글에는 공통 규칙이 그대로 적용된다.
        XCTAssertEqual(verdict("[다른카드] 승인 안내", [sharedIgnore]), .ignored)
        XCTAssertEqual(verdict("[다른카드] 안내", [sharedIgnore]), .unmatched)
    }
}
