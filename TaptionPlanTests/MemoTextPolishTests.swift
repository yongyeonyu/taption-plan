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

    // MARK: 3단계 길 (PCC1118A01)

    func testRelayRouteHandsOffWithoutChangingText() async {
        let controller = MemoPolishController(readAvailability: { .available }, reply: { _ in MemoPolishReply(text: nil, notice: .cloudQuotaReached(resetDate: nil)) })
        controller.refreshAvailability()
        var text = "메모"
        await controller.polish(currentText: { text }, apply: { text = $0 })?.value
        XCTAssertEqual(text, "메모")
        XCTAssertEqual(controller.handOffCount, 1)
        XCTAssertEqual(controller.notice, .cloudQuotaReached)
        XCTAssertFalse(MemoPolishNotice.cloudQuotaReached.isFailure)
    }

    func testRelayRouteWithoutNoticeIsFailure() async {
        let controller = MemoPolishController(readAvailability: { .available }, reply: { _ in MemoPolishReply(text: nil) })
        controller.refreshAvailability()
        await controller.polish(currentText: { "메모" }, apply: { _ in })?.value
        XCTAssertEqual(controller.notice, .failed)
    }

    func testCloudPolishKeepsQuotaNotice() async {
        let controller = MemoPolishController(readAvailability: { .available }, reply: { _ in MemoPolishReply(text: "내일 만나요.", notice: .cloudQuotaApproaching) })
        controller.refreshAvailability()
        var text = "낼 만나요"
        await controller.polish(currentText: { text }, apply: { text = $0 })?.value
        XCTAssertEqual(text, "내일 만나요.")
        XCTAssertEqual(controller.notice, .cloudQuotaApproaching)
        XCTAssertEqual(controller.handOffCount, 0)
    }

    func testRouteNoticeMapping() {
        XCTAssertEqual(MemoPolishNotice(.inputTooLongForDevice), .tooLong)
        XCTAssertEqual(MemoPolishNotice(.cloudQuotaApproaching), .cloudQuotaApproaching)
        XCTAssertNil(MemoPolishNotice(nil))
    }

    /// AI 공유 수준과 상관없이 좌표가 든 글만 PCC로 보내지 않는다(대표 결정 2026-11-18).
    func testCloudSkipsOnlyCoordinates() {
        XCTAssertTrue(AppleModelEnvironment.allowsCloud(for: "점심 12,000원"))
        XCTAssertFalse(AppleModelEnvironment.allowsCloud(for: "12.34560, 123.45670 앞"))
    }

    /// 승인 전 스위치가 꺼져 있으면 PCC를 묻지 않고 고르지도 않는다.
    @MainActor
    func testDisabledSwitchNeverPicksCloud() {
        XCTAssertFalse(AppleModelEnvironment.isPrivateCloudComputeEnabled)
        XCTAssertEqual(AppleModelEnvironment.cloudState(enabled: false), .unavailable)
        let conditions = AppleModelEnvironment.conditions(.memoPolish, text: "메모", cloudEnabled: false)
        XCTAssertEqual(conditions.cloud, .unavailable)
        XCTAssertNotEqual(AppleModelRouter.decide(conditions).route, .privateCloud)
    }

    /// entitlement 없이도 iOS가 준 상태를 읽기만 하고 멈추지 않는다. 실제 값은 기록으로 남긴다.
    @MainActor
    func testLiveConditionsReadWithoutCrash() {
        let conditions = AppleModelEnvironment.conditions(.memoPolish, text: "메모", cloudEnabled: true)
        print("PCC1118A01 live cloud=\(conditions.cloud) device=\(conditions.device) online=\(conditions.isOnline) route=\(AppleModelRouter.decide(conditions).route)")
        if #unavailable(iOS 27.0) { XCTAssertEqual(conditions.cloud, .unsupported) }
    }

    /// 요청할 때만(`TAPTION_PCC_PROBE=1`): 정해 둔 시험 글 하나를 실제 PCC에 보내 entitlement 없이 어떻게 되는지 남긴다.
    func testLiveCloudProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAPTION_PCC_PROBE"] == "1", "요청할 때만")
        do {
            let text = try await AppleCloudModel.polishMemo("낼 친구랑 점심 먹음 맛있었음")
            print("PCC1118A01 probe polished=\(text.count)")
        } catch {
            print("PCC1118A01 probe error=\(error)")
        }
        let reply = try? await MemoTextPolisher.polish("낼 친구랑 점심 먹음 맛있었음")
        print("PCC1118A01 probe routed text=\(reply?.text != nil) notice=\(String(describing: reply?.notice))")
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    func testCloudErrorsFallBackOrStayAsNotice() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("iOS 27 필요") }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: ""))
        XCTAssertEqual(AppleCloudModel.classified(quota) as? AppleCloudModel.Failure, .init(reason: .quotaReached(resetDate: reset)))
        XCTAssertEqual(AppleCloudModel.classified(PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: ""))) as? AppleCloudModel.Failure,
                       .init(reason: .network))
        XCTAssertEqual(AppleCloudModel.classified(PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: ""))) as? AppleCloudModel.Failure,
                       .init(reason: .service))
        struct Unknown: Error {}
        XCTAssertEqual(AppleCloudModel.classified(Unknown()) as? AppleCloudModel.Failure, .init(reason: .service))
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
        XCTAssertEqual(AppleCloudModel.classified(LanguageModelSession.GenerationError.guardrailViolation(context)) as? MemoPolishNotice, .blockedContent)
        XCTAssertTrue(AppleCloudModel.classified(CancellationError()) is CancellationError)
    }
    #endif

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
