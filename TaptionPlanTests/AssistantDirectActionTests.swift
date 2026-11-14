import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// APV1114A16: 승인 요청의 종류마다 있는 바로 실행 동작 — 스위치 기본값, 거절, 적용, 되돌리기.
@MainActor
final class AssistantDirectActionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15))! }

    private func defaults() -> UserDefaults {
        let name = "AssistantDirectActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func batch(_ action: String, _ extra: [String: Any]) throws -> AssistantCommandBatch {
        let item: [String: Any] = ["format": "bokki-command", "version": 1, "id": "c-\(UUID().uuidString)", "action": action, "keyId": "aaaa1111"]
        let data = try JSONSerialization.data(withJSONObject: ["commands": [item.merging(extra) { $1 }]])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: now, calendar: calendar))
    }

    private func send(_ model: AppModel, _ action: String, _ extra: [String: Any] = [:], store: UserDefaults) async throws -> (reason: String?, entry: AssistantLogEntry?) {
        let applied = await model.applyAssistantCommands(try batch(action, extra), defaults: store)
        let outcome = try XCTUnwrap(applied)
        return (outcome.results.first?.reason, outcome.entries.first)
    }

    private func switchOn(_ name: String, _ store: UserDefaults) { AssistantActionToggles.set(.operation(name), enabled: true, defaults: store) }

    private func isOn(_ name: String, _ store: UserDefaults) -> Bool { AssistantActionToggles.isEnabled(.operation(name), defaults: store) }

    func testEveryApprovalKindHasADirectActionOrStaysApprovalOnly() throws {
        // 승인 종류 → 바로 실행 동작. 전부 지우기·PIN 바꾸기는 승인 요청으로만 한다.
        let direct: [AssistantApproval.Request: [String]] = [
            .shareLevel: ["lowerShareLevel", "raiseShareLevel"], .retentionDays: ["shortenRetention", "extendRetention"],
            .healthOff: ["turnOffHealth"], .backup: ["openBackup"], .restore: ["restoreFromBackup"], .eraseAllData: [], .changePin: [],
        ]
        XCTAssertEqual(Set(direct.keys), Set(AssistantApproval.Request.allCases))
        XCTAssertTrue(direct.values.joined().allSatisfy { AssistantOperations.spec($0) != nil })
        XCTAssertEqual(AssistantOperations.direct.map { $0.spec.name }, ["lowerShareLevel", "raiseShareLevel", "shortenRetention", "extendRetention", "turnOffHealth", "openBackup"])
        XCTAssertFalse(AssistantOperations.all.contains { ["eraseAllData", "changePin", "setAppLock", "setPin"].contains($0.spec.name) })

        // 기본값: 덜 보내기·줄이기·화면 열기는 켬, 넓히기·늘리기·되돌릴 수 없는 것은 꺼짐.
        let store = defaults()
        XCTAssertEqual(["lowerShareLevel", "shortenRetention", "openBackup"].map { isOn($0, store) }, [true, true, true])
        XCTAssertEqual(["raiseShareLevel", "extendRetention", "turnOffHealth", "restoreFromBackup"].map { isOn($0, store) }, [false, false, false, false])
        let deleting = Set(AssistantActionTogglesView.kinds(deleting: true).map(\.rawValue))
        XCTAssertTrue(deleting.contains("turnOffHealth"))
        XCTAssertTrue(deleting.isDisjoint(with: ["lowerShareLevel", "raiseShareLevel", "shortenRetention", "extendRetention", "openBackup"]))

        // 읽기: 서버와 같은 값만 받는다.
        let bad: [(String, [String: Any])] = [
            ("lowerShareLevel", ["level": "visits"]), ("lowerShareLevel", [:]), ("raiseShareLevel", ["level": "off"]), ("raiseShareLevel", ["level": "all"]),
            ("shortenRetention", ["days": 30]), ("shortenRetention", ["days": 3]), ("shortenRetention", ["days": "7"]),
            ("extendRetention", ["days": 1]), ("extendRetention", ["days": 14]), ("extendRetention", ["days": 7.5]),
        ]
        for (action, extra) in bad { XCTAssertFalse(try batch(action, extra).invalidIDs.isEmpty, "\(action) \(extra)") }
        let good: [(String, [String: Any])] = [
            ("lowerShareLevel", ["level": "off"]), ("raiseShareLevel", ["level": "visits"]), ("shortenRetention", ["days": 1]),
            ("extendRetention", ["days": 30]), ("turnOffHealth", [:]), ("openBackup", [:]),
        ]
        for (action, extra) in good { XCTAssertEqual(try batch(action, extra).commands.map(\.action.kind.rawValue), [action]) }
        XCTAssertEqual(try batch("openBackup", ["password": "123456"]).commands.count, 1, "모르는 칸은 버리고 읽는다")

        // 안내문: 꺼져 있으면 승인 요청을 쓰라고 적는다.
        for type in AssistantOperations.direct { XCTAssertTrue(type.spec.guide.contains("use requestApproval instead"), type.spec.name) }
        for name in ["raiseShareLevel", "extendRetention", "turnOffHealth"] {
            XCTAssertEqual(AssistantOperations.spec(name)?.guide.contains("off until I switch it on"), true, name)
        }
    }

    func testShareLevelGoesOneWayPerActionAndUndoes() async throws {
        let store = defaults()
        let model = await makeModel()
        store.set(AssistantShareLevel.visits.rawValue, forKey: AssistantShareLevel.defaultsKey)

        // 낮추기: 기본 켬. 서버의 날들을 지우게 적어 둔다.
        let lowered = try await send(model, "lowerShareLevel", ["level": "summary"], store: store)
        XCTAssertNil(lowered.reason)
        XCTAssertEqual(AssistantShareLevel.current(store), .summary)
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey))
        XCTAssertEqual(lowered.entry?.before, "머문 곳 이름과 시각")
        XCTAssertEqual(lowered.entry?.after, "하루 요약")
        XCTAssertEqual(lowered.entry?.canUndo, true)
        let same = try await send(model, "lowerShareLevel", ["level": "summary"], store: store)
        XCTAssertEqual(same.reason, "no_change")
        store.set(AssistantShareLevel.off.rawValue, forKey: AssistantShareLevel.defaultsKey)
        let notLower = try await send(model, "lowerShareLevel", ["level": "summary"], store: store)
        XCTAssertEqual(notLower.reason, "not_lower", "낮추기로는 더 보내게 하지 못한다")
        XCTAssertEqual(AssistantShareLevel.current(store), .off)

        // 사용자가 그 뒤에 바꿨으면 되돌리지 않는다.
        let stale = await model.undoAssistantEntry(try XCTUnwrap(lowered.entry), preferences: .test(store))
        XCTAssertFalse(stale)
        store.set(AssistantShareLevel.summary.rawValue, forKey: AssistantShareLevel.defaultsKey)
        store.removeObject(forKey: AssistantActivitySync.pendingClearKey)
        let undone = await model.undoAssistantEntry(try XCTUnwrap(lowered.entry), preferences: .test(store))
        XCTAssertTrue(undone)
        XCTAssertEqual(AssistantShareLevel.current(store), .visits)
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "되돌리면 서버의 날들을 돌아간 설정으로 다시 올린다")

        // 높이기: 꺼져 있으면 거절, 켜면 적용. 더 보내는 쪽은 서버 기록을 지우지 않는다.
        store.set(AssistantShareLevel.off.rawValue, forKey: AssistantShareLevel.defaultsKey)
        store.removeObject(forKey: AssistantActivitySync.pendingClearKey)
        let refused = try await send(model, "raiseShareLevel", ["level": "visits"], store: store)
        XCTAssertEqual(refused.reason, "disabled")
        XCTAssertEqual(AssistantShareLevel.current(store), .off)
        let input = await AssistantAppStateSync.input(model: model, preferences: .test(store), now: now, calendar: calendar)
        let off = AssistantAppStateSync.make(input).settings.actionsOff
        XCTAssertTrue(Set(off).isSuperset(of: ["raiseShareLevel", "extendRetention", "turnOffHealth"]))
        XCTAssertFalse(off.contains("lowerShareLevel"))
        switchOn("raiseShareLevel", store)
        let raised = try await send(model, "raiseShareLevel", ["level": "visits"], store: store)
        XCTAssertNil(raised.reason)
        XCTAssertEqual(AssistantShareLevel.current(store), .visits)
        XCTAssertFalse(store.bool(forKey: AssistantActivitySync.pendingClearKey))
        let notHigher = try await send(model, "raiseShareLevel", ["level": "summary"], store: store)
        XCTAssertEqual(notHigher.reason, "not_higher", "높이기로는 낮추지 못한다")
        let back = await model.undoAssistantEntry(try XCTUnwrap(raised.entry), preferences: .test(store))
        XCTAssertTrue(back)
        XCTAssertEqual(AssistantShareLevel.current(store), .off)
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "높인 것을 되돌리면 더 자세히 올린 날들을 지운다")
    }

    func testRetentionGoesOneWayPerActionAndUndoes() async throws {
        let store = defaults()
        let model = await makeModel()
        XCTAssertEqual(AssistantRetention.current(store), .week)

        let refused = try await send(model, "extendRetention", ["days": 30], store: store)
        XCTAssertEqual(refused.reason, "disabled")
        XCTAssertEqual(AssistantRetention.current(store), .week)
        switchOn("extendRetention", store)
        let extended = try await send(model, "extendRetention", ["days": 30], store: store)
        XCTAssertNil(extended.reason)
        XCTAssertEqual(AssistantRetention.current(store), .month)
        XCTAssertFalse(store.bool(forKey: AssistantActivitySync.pendingClearKey), "늘리면 서버 기록을 지우지 않는다")
        XCTAssertEqual(extended.entry?.before, "7일")
        XCTAssertEqual(extended.entry?.after, "30일")
        let notLonger = try await send(model, "extendRetention", ["days": 7], store: store)
        XCTAssertEqual(notLonger.reason, "not_longer")
        let back = await model.undoAssistantEntry(try XCTUnwrap(extended.entry), preferences: .test(store))
        XCTAssertTrue(back)
        XCTAssertEqual(AssistantRetention.current(store), .week)
        XCTAssertNil(store.object(forKey: AssistantRetention.defaultsKey), "정하기 전으로 돌아간다")
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "늘린 것을 되돌리면 서버의 날들을 지운다")

        store.removeObject(forKey: AssistantActivitySync.pendingClearKey)
        let shortened = try await send(model, "shortenRetention", ["days": 1], store: store)
        XCTAssertNil(shortened.reason)
        XCTAssertEqual(AssistantRetention.current(store), .oneDay)
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "줄이면 서버 기록을 지운다")
        let notShorter = try await send(model, "shortenRetention", ["days": 7], store: store)
        XCTAssertEqual(notShorter.reason, "not_shorter")
        let same = try await send(model, "shortenRetention", ["days": 1], store: store)
        XCTAssertEqual(same.reason, "no_change")
        let undone = await model.undoAssistantEntry(try XCTUnwrap(shortened.entry), preferences: .test(store))
        XCTAssertTrue(undone)
        XCTAssertEqual(AssistantRetention.current(store), .week)

        AssistantActionToggles.set(.operation("shortenRetention"), enabled: false, defaults: store)
        let off = try await send(model, "shortenRetention", ["days": 1], store: store)
        XCTAssertEqual(off.reason, "disabled", "끈 사용자는 승인 요청으로 받는다")
        XCTAssertEqual(AssistantRetention.current(store), .week)
    }

    func testHealthOffStartsOffAndCannotBeUndoneAndBackupOnlyOpensTheScreen() async throws {
        let store = defaults()
        let model = await makeModel()
        model.snapshot.settings.healthEnabled = true

        let refused = try await send(model, "turnOffHealth", store: store)
        XCTAssertEqual(refused.reason, "disabled")
        XCTAssertTrue(model.settings.healthEnabled)
        switchOn("turnOffHealth", store)
        let stopped = try await send(model, "turnOffHealth", store: store)
        XCTAssertNil(stopped.reason)
        XCTAssertFalse(model.settings.healthEnabled)
        XCTAssertEqual(stopped.entry?.irreversible, true)
        XCTAssertEqual(stopped.entry?.canUndo, false)
        let failed = await model.undoAssistantEntry(try XCTUnwrap(stopped.entry), preferences: .test(store))
        XCTAssertFalse(failed)
        XCTAssertFalse(model.settings.healthEnabled)
        let again = try await send(model, "turnOffHealth", store: store)
        XCTAssertEqual(again.reason, "no_change")

        // 백업: 기본 켬, 화면만 열고 되돌리면 거둔다.
        func pending() -> AssistantScreen? { AssistantScreenRequest(defaults: store).pending }
        let opened = try await send(model, "openBackup", store: store)
        XCTAssertNil(opened.reason)
        XCTAssertEqual(pending(), .dataProtection)
        let withdrawn = await model.undoAssistantEntry(try XCTUnwrap(opened.entry), preferences: .test(store))
        XCTAssertTrue(withdrawn)
        XCTAssertNil(pending())
        AssistantActionToggles.set(.operation("openBackup"), enabled: false, defaults: store)
        let off = try await send(model, "openBackup", store: store)
        XCTAssertEqual(off.reason, "disabled")
        XCTAssertNil(pending())

        // 예전 승인 흐름은 그대로다: 스위치를 꺼도 승인 요청은 받는다.
        let asked = try await send(model, "requestApproval", ["request": "backup"], store: store)
        XCTAssertNil(asked.reason)
        XCTAssertEqual(AssistantQuestionStore(defaults: store).waiting.compactMap(\.approval?.request), [.backup])
    }
}
