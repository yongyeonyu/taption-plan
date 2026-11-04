import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import TaptionPlan

@MainActor
final class MemoTextPolishTests: XCTestCase {
    private func controller(
        availability: MemoPolishAvailability = .available,
        polisher: @escaping @Sendable (String) async throws -> String
    ) -> MemoPolishController {
        let controller = MemoPolishController(readAvailability: { availability }, polisher: polisher)
        controller.refreshAvailability()
        return controller
    }

    // MARK: 가용성

    func testOnlyUnsupportedHidesButton() {
        XCTAssertTrue(MemoPolishAvailability.available.showsButton)
        XCTAssertTrue(MemoPolishAvailability.appleIntelligenceOff.showsButton)
        XCTAssertTrue(MemoPolishAvailability.modelNotReady.showsButton)
        XCTAssertFalse(MemoPolishAvailability.unsupported.showsButton)
    }

    func testSystemAvailabilityMapping() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw XCTSkip("iOS 26 필요") }
        XCTAssertEqual(FoundationMemoPolisher.mapped(.available), .available)
        XCTAssertEqual(FoundationMemoPolisher.mapped(.unavailable(.appleIntelligenceNotEnabled)), .appleIntelligenceOff)
        XCTAssertEqual(FoundationMemoPolisher.mapped(.unavailable(.modelNotReady)), .modelNotReady)
        XCTAssertEqual(FoundationMemoPolisher.mapped(.unavailable(.deviceNotEligible)), .unsupported)
        #endif
    }

    func testCanPolishNeedsTextAndAvailableModel() {
        let ready = controller { $0 }
        XCTAssertFalse(ready.canPolish(" \n "))
        XCTAssertTrue(ready.canPolish("메모"))
        for state in [MemoPolishAvailability.appleIntelligenceOff, .modelNotReady, .unsupported] {
            XCTAssertFalse(controller(availability: state) { $0 }.canPolish("메모"))
        }
    }

    // MARK: 지시문

    func testInstructionsFollowMemoLanguageAndForbidInvention() {
        XCTAssertTrue(MemoPolishFormat.instructions(for: "회의 메모").contains("지어내지 않"))
        XCTAssertTrue(MemoPolishFormat.instructions(for: "meeting note").contains("do not translate"))
        XCTAssertEqual(MemoPolishFormat.prompt(for: "글"), "<memo>\n글\n</memo>")
    }

    // MARK: 결과 검증

    func testValidatedAcceptsCorrection() throws {
        XCTAssertEqual(
            try MemoPolishFormat.validated(output: " <memo>내일 3시에 만나요.</memo>\n", original: "낼 3시에 만나요"),
            .polished("내일 3시에 만나요.")
        )
    }

    func testValidatedReportsUnchanged() throws {
        XCTAssertEqual(try MemoPolishFormat.validated(output: "그대로", original: " 그대로\n"), .unchanged)
    }

    func testValidatedTreatsThousandsSeparatorAsSameNumber() throws {
        XCTAssertEqual(
            try MemoPolishFormat.validated(output: "1,000원을 냈다.", original: "1000원을 냈다"),
            .polished("1,000원을 냈다.")
        )
    }

    func testValidatedAcceptsLongerRewrite() throws {
        let output = "오늘은 아침부터 일정이 많아 정신없이 하루를 보냈고, 저녁이 되어서야 겨우 한숨을 돌릴 수 있었다."
        XCTAssertEqual(try MemoPolishFormat.validated(output: output, original: "오늘 바빴다"), .polished(output))
    }

    func testValidatedRejectsChangedMeaning() {
        let rejected: [(output: String, original: String)] = [
            ("", "메모"),
            ("내일 4시에 만나요", "내일 3시에 만나요"),
            ("내일 만나요", "내일 3시에 만나요"),
            ("Let's meet tomorrow", "내일 만나요"),
            ("내일 만나요", "See you tomorrow"),
            (String(repeating: "길게 늘인 문장입니다. ", count: 20), "내일 만나요"),
            ("회의", "오늘 오후에 팀 회의를 했고 다음 주 일정을 정했다"),
        ]
        for item in rejected {
            XCTAssertThrowsError(try MemoPolishFormat.validated(output: item.output, original: item.original), item.output) {
                XCTAssertEqual($0 as? MemoPolishNotice, .rejected)
            }
        }
    }

    // MARK: 되돌리기

    func testSwapRestoresOriginalAndBack() {
        var history = MemoPolishHistory()
        XCTAssertFalse(history.canSwap)
        history.recordPolish(from: "원문", to: "다듬은 글")
        XCTAssertEqual(history.swap(current: "다듬은 글"), "원문")
        XCTAssertTrue(history.isShowingOriginal)
        XCTAssertEqual(history.swap(current: "원문"), "다듬은 글")
        XCTAssertFalse(history.isShowingOriginal)
    }

    func testSwapKeepsEditsMadeAfterPolish() {
        var history = MemoPolishHistory()
        history.recordPolish(from: "원문", to: "다듬은 글")
        XCTAssertEqual(history.swap(current: "다듬은 글 더 씀"), "원문")
        XCTAssertEqual(history.swap(current: "원문"), "다듬은 글 더 씀")
    }

    func testRepeatedPolishKeepsFirstOriginal() {
        var history = MemoPolishHistory()
        history.recordPolish(from: "원문", to: "두 번째")
        history.recordPolish(from: "두 번째", to: "세 번째")
        XCTAssertEqual(history.swap(current: "세 번째"), "원문")
    }

    func testPolishAfterEditUsesEditedTextAsOriginal() {
        var history = MemoPolishHistory()
        history.recordPolish(from: "원문", to: "다듬은 글")
        history.recordPolish(from: "직접 고친 글", to: "다시 다듬은 글")
        XCTAssertEqual(history.swap(current: "다시 다듬은 글"), "직접 고친 글")
    }

    func testPolishAfterUndoStartsFromShownOriginal() {
        var history = MemoPolishHistory()
        history.recordPolish(from: "원문", to: "다듬은 글")
        _ = history.swap(current: "다듬은 글")
        history.recordPolish(from: "원문", to: "새로 다듬은 글")
        XCTAssertFalse(history.isShowingOriginal)
        XCTAssertEqual(history.swap(current: "새로 다듬은 글"), "원문")
    }

    // MARK: 흐름

    func testPolishAppliesResultAndAllowsUndo() async {
        let controller = controller { _ in "내일 만나요." }
        var text = "낼 만나요"
        await controller.polish(currentText: { text }, apply: { text = $0 })?.value
        XCTAssertEqual(text, "내일 만나요.")
        XCTAssertFalse(controller.isPolishing)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.swap(current: text), "낼 만나요")
    }

    func testTextEditedDuringPolishIsNotOverwritten() async {
        let controller = controller { _ in "내일 만나요." }
        var text = "낼 만나요"
        let task = controller.polish(currentText: { text }, apply: { text = $0 })
        text = "낼 만나요 그리고"
        await task?.value
        XCTAssertEqual(text, "낼 만나요 그리고")
        XCTAssertEqual(controller.notice, .textChanged)
        XCTAssertFalse(controller.history.canSwap)
    }

    func testFailureKeepsTextAndShowsNotice() async {
        let controller = controller { _ in throw MemoPolishNotice.blockedContent }
        var text = "메모"
        await controller.polish(currentText: { text }, apply: { text = $0 })?.value
        XCTAssertEqual(text, "메모")
        XCTAssertEqual(controller.notice, .blockedContent)
        XCTAssertFalse(controller.isPolishing)
    }

    func testRejectedOutputKeepsText() async {
        let controller = controller { _ in "내일 9시에 만나요" }
        var text = "내일 3시에 만나요"
        await controller.polish(currentText: { text }, apply: { text = $0 })?.value
        XCTAssertEqual(text, "내일 3시에 만나요")
        XCTAssertEqual(controller.notice, .rejected)
    }

    func testTooLongTextSkipsModel() {
        let controller = controller { _ in
            XCTFail("모델을 부르면 안 된다")
            return ""
        }
        let text = String(repeating: "가", count: MemoPolishFormat.maxInputLength + 1)
        XCTAssertNil(controller.polish(currentText: { text }, apply: { _ in }))
        XCTAssertEqual(controller.notice, .tooLong)
    }

    func testCancelDropsLateResult() async {
        let controller = controller { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return "늦은 결과"
        }
        var text = "메모"
        let task = controller.polish(currentText: { text }, apply: { text = $0 })
        controller.cancel()
        await task?.value
        XCTAssertEqual(text, "메모")
        XCTAssertFalse(controller.isPolishing)
    }

    #if canImport(FoundationModels)
    func testGenerationErrorsMapToNotices() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("iOS 26 필요") }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
        XCTAssertEqual(
            FoundationMemoPolisher.notice(for: LanguageModelSession.GenerationError.guardrailViolation(context)) as? MemoPolishNotice,
            .blockedContent
        )
        XCTAssertEqual(
            FoundationMemoPolisher.notice(for: LanguageModelSession.GenerationError.exceededContextWindowSize(context)) as? MemoPolishNotice,
            .tooLong
        )
        XCTAssertEqual(
            FoundationMemoPolisher.notice(for: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)) as? MemoPolishNotice,
            .unsupportedLanguage
        )
        XCTAssertTrue(FoundationMemoPolisher.notice(for: CancellationError()) is CancellationError)
    }
    #endif
}
