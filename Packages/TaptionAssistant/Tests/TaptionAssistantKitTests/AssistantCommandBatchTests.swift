import Foundation
import TaptionAssistantProtocol
import XCTest
@testable import TaptionAssistantKit

/// 명령 묶음을 걸러 내는 규칙(RMN1114A25): 이미 처리한 것, 반영 중인 것, 살아 있지 않은 연결이 보낸 것.
final class AssistantCommandBatchTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AssistantCommandBatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func command(_ id: String, keyID: String? = nil, source: String? = nil) -> AssistantCommand {
        AssistantCommand(id: id, action: .deleteMemo(memoID: "m"), keyID: keyID, source: source)
    }

    func testKindFollowsTheAction() {
        XCTAssertEqual(command("a").action.kind, .deleteMemo)
        XCTAssertEqual(AssistantCommand.Action.setBudget(month: "2026-11", amountKRW: 1).kind, .setBudget)
        XCTAssertEqual(AssistantCommand.Action.setBubble(start: .distantPast, end: .distantFuture, text: "a").kind, .setBubble)
        let parsed = AssistantOperations.parse(AssistantFields(values: [
            "format": .text("bokki-command"), "version": .number(1), "action": .text("openBackup"),
        ]))
        XCTAssertEqual(parsed.map { AssistantCommand.Action.operation($0).kind }, .operation("openBackup"))
    }

    func testBatchDropsHandledAndClaimedCommands() {
        let store = defaults()
        let info = ["x": AssistantCommandBatch.Invalid(kind: .addMemo, keyID: "k")]
        let batch = AssistantCommandBatch(commands: [command("a"), command("b"), command("c")], invalidIDs: ["x", "y"], invalidInfo: info)
        AssistantCommandLedger.remember(["a", "y"], defaults: store)
        let unseen = AssistantCommandLedger.unseen(batch, defaults: store)
        XCTAssertEqual(unseen.commands.map(\.id), ["b", "c"])
        XCTAssertEqual(unseen.invalidIDs, ["x"])
        XCTAssertEqual(unseen.invalidInfo, info)
        let rest = unseen.excluding(["c", "x"])
        XCTAssertEqual(rest.commands.map(\.id), ["b"])
        XCTAssertTrue(rest.invalidIDs.isEmpty)
    }

    func testOnlyLiveConnectionsAndLegacyQueueAreKept() {
        let batch = AssistantCommandBatch(
            commands: [command("live", keyID: "k1"), command("revoked", keyID: "k2"), command("legacy", source: "legacy"), command("master", source: "master"), command("bare")],
            invalidIDs: ["x"]
        )
        let split = AssistantKeyFilter.split(batch, active: ["k1"])
        XCTAssertEqual(split.kept.commands.map(\.id), ["live", "legacy"])
        XCTAssertEqual(split.inactiveIDs, ["revoked", "master", "bare"])
        XCTAssertEqual(split.kept.invalidIDs, ["x"])
    }
}
