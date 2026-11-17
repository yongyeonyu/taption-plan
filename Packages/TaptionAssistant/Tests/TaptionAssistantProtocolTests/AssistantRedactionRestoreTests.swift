import XCTest
@testable import TaptionAssistantProtocol

/// REV1117A02: 하루 기록으로 보내는 메모는 번호를 가린다. AI가 그 사본을 고쳐 돌려보내도 원문 번호는 지워지지 않는다.
final class AssistantRedactionRestoreTests: XCTestCase {
    func testAMaskedNumberTheAIEchoesBackIsRestoredFromTheOriginal() {
        let original = "택배 기사 010-1234-5678 문 앞, 카드 1234 5678 9012 3456"
        let sent = AssistantRedaction.mask(original)
        XCTAssertFalse(sent.contains("1234-5678"))
        XCTAssertFalse(sent.contains("9012"))
        let edited = "택배: 기사님 " + sent.replacingOccurrences(of: "택배 기사 ", with: "")
        let restored = AssistantRedaction.restore(edited, original: original)
        XCTAssertTrue(restored.contains("010-1234-5678"), restored)
        XCTAssertTrue(restored.contains("1234 5678 9012 3456"), restored)
    }

    /// AIF1118A01: 띄어 쓴 전화번호, +82 국제 번호, Amex 4-6-5, 메일 주소도 가리고, AI가 돌려보내면 원문으로 되돌린다.
    func testSpacedPhonesInternationalNumbersAmexAndEmailsAreMaskedAndRestored() {
        let original = "기사 010 1234 5678, 해외 +82 10-9876-5432, 사무실 02.123.4567, 카드 3782 822463 10005, 메일 minsu.kim@example.com 연락"
        let sent = AssistantRedaction.mask(original)
        for secret in ["010 1234", "+82 10-9876", "02.123", "3782 822463", "minsu.kim@", "insu.kim"] {
            XCTAssertFalse(sent.contains(secret), "\(secret) leaked: \(sent)")
        }
        XCTAssertTrue(sent.contains("5678") && sent.contains("5432") && sent.contains("0005"), "the last four digits stay: \(sent)")
        XCTAssertTrue(sent.contains("@example.com"), sent)
        XCTAssertEqual(AssistantRedaction.restore(sent, original: original), original)
    }

    func testAmountsDatesAndTimesAreNotMaskedByTheWiderPatterns() {
        let text = "점심 12,000원 2026-11-18 08:12 잔액 1,234,567원 11/18 3명 10 20 30분"
        XCTAssertEqual(AssistantRedaction.mask(text), text)
    }

    /// 두 원문 번호가 같은 가린 모양이면 어느 쪽인지 몰라 되돌리지 않는다.
    func testAmbiguousMaskedFormsAreNotRestored() {
        let original = "a 010-1111-5678 b 010-2222-5678"
        let sent = AssistantRedaction.mask(original)
        XCTAssertEqual(AssistantRedaction.restore(sent, original: original), sent)
    }

    func testTextWithoutMaskedNumbersIsLeftAlone() {
        XCTAssertEqual(AssistantRedaction.restore("점심 12,000원", original: "점심 12000원"), "점심 12,000원")
        XCTAssertEqual(AssistantRedaction.restore("새 번호 010-9999-0000", original: "010-1234-5678"), "새 번호 010-9999-0000")
    }
}
