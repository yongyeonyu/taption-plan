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

    func testTextWithoutMaskedNumbersIsLeftAlone() {
        XCTAssertEqual(AssistantRedaction.restore("점심 12,000원", original: "점심 12000원"), "점심 12,000원")
        XCTAssertEqual(AssistantRedaction.restore("새 번호 010-9999-0000", original: "010-1234-5678"), "새 번호 010-9999-0000")
    }
}
