import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// AI 비서 2단계: 기존 항목 고치기 명령·안전장치·AI용 키(AIR1110A02·SEC1110A01·CLN1110A01).
@MainActor
final class AssistantCommandEditTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantCommandEditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func batch(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(15), calendar: calendar))
    }

    private func command(_ id: String, _ action: String, _ extra: [String: Any]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": action].merging(extra) { $1 }
    }

    private let recordID = UUID().uuidString
    private let planID = UUID().uuidString
    private let memoID = UUID().uuidString

    // MARK: - 읽기·검사

    func testEditCommandsParseAndRejectBadShapes() throws {
        let parsed = try batch([
            command("h1", "hideRecord", ["date": "2026-11-10", "recordId": recordID]),
            command("h2", "hideRecord", ["date": "2026-11-10", "startTime": "12:30"]),
            command("h3", "hideRecord", ["date": "2026-11-10"]),
            command("h4", "hideRecord", ["recordId": recordID]),
            command("g1", "mergeRecords", ["date": "2026-11-10", "recordIds": ["a", "b"], "title": "업무"]),
            command("g2", "mergeRecords", ["date": "2026-11-10", "recordIds": ["a"]]),
            command("g3", "mergeRecords", ["date": "2026-11-10", "recordIds": ["a", "a"]]),
            command("g4", "mergeRecords", ["date": "2026-11-10", "recordIds": (0..<21).map { "r\($0)" }]),
            command("t1", "updateRecordTime", ["date": "2026-11-10", "recordId": recordID, "start": "09:30"]),
            command("t2", "updateRecordTime", ["date": "2026-11-10", "recordId": recordID]),
            command("t3", "updateRecordTime", ["date": "2026-11-10", "recordId": recordID, "end": "25:00"]),
            command("s1", "updateSchedule", ["planId": planID, "title": "치과", "start": "2026-11-12T16:00+09:00"]),
            command("s2", "updateSchedule", ["date": "2026-11-12", "startTime": "15:00", "end": "17:00"]),
            command("s3", "updateSchedule", ["planId": planID]),
            command("s4", "updateSchedule", ["date": "2026-11-12", "title": "치과"]),
            command("d1", "deleteSchedule", ["planId": planID]),
            command("d2", "deleteSchedule", ["date": "2026-11-12", "startTime": "15:00"]),
            command("d3", "deleteSchedule", [:]),
            command("m1", "updateMemo", ["memoId": memoID, "text": "새 글"]),
            command("m2", "updateMemo", ["memoId": memoID, "text": "  "]),
            command("m3", "deleteMemo", ["memoId": memoID]),
            command("m4", "deleteMemo", [:]),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["h1", "h2", "g1", "t1", "s1", "s2", "d1", "d2", "m1", "m3"])
        XCTAssertEqual(parsed.invalidIDs, ["h3", "h4", "g2", "g3", "g4", "t2", "t3", "s3", "s4", "d3", "m2", "m4"])
        let actions = parsed.commands.map(\.action)
        XCTAssertEqual(actions[0], .hideRecord(day: at(0), recordID: recordID, startTime: nil))
        XCTAssertEqual(actions[1], .hideRecord(day: at(0), recordID: nil, startTime: at(12, 30)))
        XCTAssertEqual(actions[2], .mergeRecords(day: at(0), recordIDs: ["a", "b"], title: "업무", categoryID: nil))
        XCTAssertEqual(actions[3], .updateRecordTime(day: at(0), recordID: recordID, start: at(9, 30), end: nil))
        XCTAssertEqual(actions[4], .updateSchedule(
            target: AssistantPlanTarget(planID: planID, startTime: nil), title: "치과",
            start: .instant(at(16, day: 12)), end: nil, note: nil
        ))
        XCTAssertEqual(actions[5], .updateSchedule(
            target: AssistantPlanTarget(planID: nil, startTime: at(15, day: 12)), title: nil,
            start: nil, end: .clock(hour: 17, minute: 0), note: nil
        ))
        XCTAssertEqual(actions[7], .deleteSchedule(target: AssistantPlanTarget(planID: nil, startTime: at(15, day: 12))))
        XCTAssertEqual(actions[8], .updateMemo(memoID: memoID, text: "새 글"))
        XCTAssertEqual(actions[9], .deleteMemo(memoID: memoID))
        XCTAssertEqual(actions.map(\.kind), [.hideRecord, .hideRecord, .mergeRecords, .updateRecordTime, .updateSchedule, .updateSchedule, .deleteSchedule, .deleteSchedule, .updateMemo, .deleteMemo])
    }

    func testRetimeCrossesMidnightOnlyWhenBothEndsAreGiven() {
        let span = AssistantMergePlan.retimed(start: at(9), end: at(18), newStart: at(23), newEnd: at(7))
        XCTAssertEqual(span, TimeSpan(start: at(23), end: at(7, day: 11)))
        XCTAssertNil(AssistantMergePlan.retimed(start: at(9), end: at(18), newStart: at(19), newEnd: nil))
        XCTAssertEqual(AssistantMergePlan.retimed(start: at(9), end: at(18), newStart: nil, newEnd: at(17)), TimeSpan(start: at(9), end: at(17)))
    }

    func testMergeNeedsBackToBackRecords() {
        let a = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(9), endedAt: at(10), source: .location)
        let b = ActualRecord(planID: nil, title: "회의", categoryID: "work", startedAt: at(10, 10), endedAt: at(11), source: .location)
        let far = ActualRecord(planID: nil, title: "점심", categoryID: "eating", startedAt: at(12), endedAt: at(13), source: .motion)
        XCTAssertEqual(AssistantMergePlan.span([b, a]), TimeSpan(start: at(9), end: at(11)))
        XCTAssertNil(AssistantMergePlan.span([a, b, far]), "a 60 minute gap is not consecutive")
    }

    // MARK: - 안전장치

    func testBatchOverTwentyExistingChangesNeedsConfirmation() throws {
        let store = defaults()
        let memoEdits = (0..<20).map { command("m\($0)", "updateMemo", ["memoId": UUID().uuidString, "text": "글"]) }
        let adds = (0..<10).map { command("a\($0)", "addMemo", ["text": "새 메모"]) }
        let twenty = try batch(memoEdits + adds)
        XCTAssertEqual(AssistantBatchPolicy.changeCount(twenty, defaults: store), 20, "new items do not count")
        XCTAssertFalse(AssistantBatchPolicy.needsConfirmation(twenty, defaults: store))
        let merge = command("g", "mergeRecords", ["date": "2026-11-10", "recordIds": ["a", "b"]])
        let over = try batch(memoEdits + [merge])
        XCTAssertEqual(AssistantBatchPolicy.changeCount(over, defaults: store), 22)
        XCTAssertTrue(AssistantBatchPolicy.needsConfirmation(over, defaults: store))
        AssistantActionToggles.set(.updateMemo, enabled: false, defaults: store)
        XCTAssertFalse(AssistantBatchPolicy.needsConfirmation(over, defaults: store), "turned-off actions are rejected, not counted")
    }

    func testActionTogglesDefaultOnAndRejectWhenOff() async throws {
        let store = defaults()
        XCTAssertTrue(AssistantActionKind.allCases.allSatisfy { AssistantActionToggles.isEnabled($0, defaults: store) })
        AssistantActionToggles.set(.deleteMemo, enabled: false, defaults: store)
        XCTAssertFalse(AssistantActionToggles.isEnabled(.deleteMemo, defaults: store))
        XCTAssertTrue(AssistantActionToggles.isEnabled(.updateMemo, defaults: store))

        let model = try await makeModel(actuals: [])
        let applied = await model.applyAssistantCommands(try batch([command("x", "deleteMemo", ["memoId": memoID])]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results, [.init(id: "x", applied: false, reason: "disabled")])
        XCTAssertTrue(outcome.entries.isEmpty)
    }

    /// AIP1114A05: 거절한 명령도 사유·맡긴 일 id와 함께 「AI가 한 일」에 남고, 되돌릴 수는 없다.
    func testRejectedCommandsAreLoggedWithReasonAndTaskID() async throws {
        let store = defaults()
        let journal = AssistantCommandJournal(defaults: store)
        addTeardownBlock { try? FileManager.default.removeItem(at: journal.logFile) }
        AssistantActionToggles.set(.deleteMemo, enabled: false, defaults: store)
        let parsed = try batch([
            command("off", "deleteMemo", ["memoId": memoID, "taskId": "task-1"]),
            command("gone", "updateMemo", ["memoId": memoID, "text": "글", "taskId": "task-1"]),
            command("bad", "updateMemo", ["memoId": memoID, "taskId": "task-1"]),
            command("ok", "addMemo", ["text": "새 메모", "taskId": "task-1"]),
            command("free", "addMemo", ["text": "다른 메모"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.taskID), ["task-1", "task-1", "task-1", nil])
        XCTAssertEqual(parsed.invalidInfo["bad"], .init(kind: .updateMemo, keyID: nil, source: nil, taskID: "task-1"))

        let model = try await makeModel(actuals: [])
        let applied = await model.applyAssistantCommands(parsed, defaults: store, journal: journal)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.entries.map(\.commandID), ["ok", "free"], "only applied commands count as edits")
        let log = AssistantActionLog.load(from: journal.logFile)
        let reasons = Dictionary(uniqueKeysWithValues: log.map { ($0.commandID, $0.rejectedReason ?? "applied") })
        XCTAssertEqual(reasons["off"], "disabled")
        XCTAssertEqual(reasons["bad"], "invalid")
        XCTAssertEqual(reasons["ok"], "applied")
        XCTAssertEqual(reasons["free"], "applied")
        XCTAssertNotEqual(reasons["gone"], "applied")
        XCTAssertNotNil(reasons["gone"])

        let task = AITaskQueue.Task(id: "task-1", kind: .other, status: .done)
        let linked = AssistantTaskEdits.entries(for: task, in: log)
        XCTAssertEqual(Set(linked.map(\.commandID)), ["off", "gone", "bad", "ok"])
        XCTAssertEqual(linked.filter(\.canUndo).map(\.commandID), ["ok"])
        let rejected = try XCTUnwrap(linked.first { $0.commandID == "gone" })
        XCTAssertTrue(rejected.delta.isEmpty)
        let undone = await model.undoAssistantEntry(rejected, preferences: .test(store))
        XCTAssertFalse(undone, "a rejected command has nothing to undo")

        // 반영 도중 꺼진 명령은 거절 기록만 있으면 반영된 것으로 치지 않는다.
        journal.begin("gone")
        journal.resolveInterrupted()
        XCTAssertEqual(journal.pending.last, .init(id: "gone", applied: false, reason: "interrupted"))
    }

    // MARK: - 기록 교정과 되돌리기

    private lazy var walk = ActualRecord(planID: nil, title: "걷기", categoryID: "movement", startedAt: at(8, 30), endedAt: at(9), source: .motion, evidence: ["걸음"])
    private lazy var work = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(9), endedAt: at(18), source: .location, evidence: ["사무실"])

    private func makeModel(actuals: [ActualRecord]) async throws -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        model.snapshot.actuals = actuals
        return model
    }

    private func apply(_ model: AppModel, _ item: [String: Any]) async throws -> AssistantLogEntry {
        let applied = await model.applyAssistantCommands(try batch([item]), defaults: defaults())
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results.map(\.applied), [true], "\(outcome.results)")
        return try XCTUnwrap(outcome.entries.first)
    }

    func testHideRecordIsACorrectionAndCanBeUndone() async throws {
        let model = try await makeModel(actuals: [walk, work])
        let entry = try await apply(model, command("h", "hideRecord", ["date": "2026-11-10", "recordId": work.id.uuidString]))
        XCTAssertEqual(model.snapshot.settings.activityCorrections[work.id]?.categoryID, "unconfirmed")
        let shown = try XCTUnwrap(model.snapshot.actuals.first { $0.id == work.id }, "the automatic record is kept")
        XCTAssertEqual(shown.source, .location)
        XCTAssertEqual(shown.evidence, ["사무실"])
        XCTAssertEqual(shown.startedAt, work.startedAt)
        XCTAssertEqual(entry.delta.actuals.first?.before, work, "the original is kept for undo")
        XCTAssertFalse(model.snapshot.settings.suppressedActualIDs.contains(work.id), "not deleted")

        let undone = await model.undoAssistantEntry(entry)
        XCTAssertTrue(undone)
        XCTAssertNil(model.snapshot.settings.activityCorrections[work.id])
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == work.id }, work)
    }

    func testMergeRecordsAddsOneUserBlockOverUntouchedRecords() async throws {
        let model = try await makeModel(actuals: [walk, work])
        let entry = try await apply(model, command("g", "mergeRecords", [
            "date": "2026-11-10", "recordIds": [walk.id.uuidString, work.id.uuidString], "title": "출근과 업무",
        ]))
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == walk.id }, walk)
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == work.id }, work)
        let block = try XCTUnwrap(model.snapshot.actuals.first { $0.source == .manual })
        XCTAssertEqual(block.title, "출근과 업무")
        XCTAssertEqual(block.categoryID, "work", "the longest record's category")
        XCTAssertEqual(block.startedAt, at(8, 30))
        XCTAssertEqual(block.endedAt, at(18))
        XCTAssertTrue(block.manuallyCorrected)

        let undone = await model.undoAssistantEntry(entry)
        XCTAssertTrue(undone)
        XCTAssertFalse(model.snapshot.actuals.contains { $0.source == .manual })
        XCTAssertEqual(Set(model.snapshot.actuals.map(\.id)), [walk.id, work.id])
    }

    func testUpdateRecordTimeWritesOnlyTheCorrectionAndCanBeUndone() async throws {
        let model = try await makeModel(actuals: [walk, work])
        let entry = try await apply(model, command("t", "updateRecordTime", ["date": "2026-11-10", "recordId": work.id.uuidString, "start": "09:30"]))
        let correction = try XCTUnwrap(model.snapshot.settings.activityCorrections[work.id])
        XCTAssertEqual(correction.startedAt, at(9, 30))
        XCTAssertEqual(correction.endedAt, at(18))
        XCTAssertEqual(correction.title, "업무")
        let shown = try XCTUnwrap(model.snapshot.actuals.first { $0.id == work.id })
        XCTAssertEqual(shown.source, .location, "provenance is kept")
        XCTAssertEqual(entry.before, "09:00–18:00 업무")
        XCTAssertEqual(entry.after, "09:30–18:00 업무")

        let undone = await model.undoAssistantEntry(entry)
        XCTAssertTrue(undone)
        XCTAssertNil(model.snapshot.settings.activityCorrections[work.id])
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == work.id }, work)
    }

    func testUnknownRecordIsRejected() async throws {
        let model = try await makeModel(actuals: [work])
        let applied = await model.applyAssistantCommands(
            try batch([command("t", "updateRecordTime", ["date": "2026-11-10", "recordId": UUID().uuidString, "end": "19:00"])]),
            defaults: defaults()
        )
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results, [.init(id: "t", applied: false, reason: "no_record")])
    }

    // MARK: - 되돌리기 값

    func testUndoRestoresDeletedPlanUnderNewIDAndRefusesAfterLaterEdits() throws {
        let plan = PlanRecord(title: "치과", span: TimeSpan(start: at(15), end: at(16)), categoryID: "activity")
        let memo = ActionMemo(planID: plan.id, occurredAt: at(15), kind: .idea, text: "검진")
        var before = TaptionDataSnapshot.empty
        before.plans = [plan]
        before.memos = [memo]
        var after = before
        after.plans = []
        after.memos[0].planID = nil
        let delta = AssistantEditDelta.difference(from: before, to: after, actualIDs: [])
        let newID = UUID()
        let restored = try XCTUnwrap(delta.undoing(in: after, newID: { newID }))
        XCTAssertEqual(restored.plans.map(\.id), [newID], "a fresh id avoids the iCloud deletion mark")
        XCTAssertEqual(restored.plans.first?.title, "치과")
        XCTAssertEqual(restored.memos.first?.planID, newID)

        var edited = after
        edited.memos[0].text = "사용자가 고침"
        XCTAssertNil(delta.undoing(in: edited), "a later user edit wins")
    }

    // MARK: - 키

    func testConnectionKeyRequestsAndListParsing() throws {
        let now = at(12)
        XCTAssertEqual(TripRelay.expiry(for: .month, from: now), now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(TripRelay.expiry(for: .quarter, from: now), now.addingTimeInterval(90 * 86_400))
        XCTAssertEqual(TripRelay.expiry(for: .year, from: now), now.addingTimeInterval(365 * 86_400))
        XCTAssertNil(TripRelay.expiry(for: .never, from: now))
        let token = String(repeating: "S", count: 43)
        let body = try XCTUnwrap(TripRelay.keysBody(token: token, scope: .write, expiresAt: now))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]])
        XCTAssertEqual(object["keys"]?.first, ["token": token, "scope": "write", "expiresAt": "2026-11-10T03:00:00Z"])
        XCTAssertEqual(AssistantKeyStore.keyID(token).count, 8)
        XCTAssertTrue(AssistantKeyStore.keyID(token).allSatisfy(\.isHexDigit))

        // 만료 없음은 칸을 빼지 않고 JSON null로 보낸다.
        let never = try XCTUnwrap(TripRelay.keysBody(token: token, scope: .read, expiresAt: nil))
        let neverKey = try XCTUnwrap((JSONSerialization.jsonObject(with: never) as? [String: [[String: Any]]])?["keys"]?.first)
        XCTAssertTrue(neverKey["expiresAt"] is NSNull)
        XCTAssertTrue(String(decoding: never, as: UTF8.self).contains(#""expiresAt":null"#))

        let list = Data(#"{"keys":[{"id":"ab12cd34","scope":"read","expiresAt":"2027-11-10T03:00:00.000Z"},{"id":"cd34ef56","scope":"write","expiresAt":null},{"id":"bad","scope":"admin","expiresAt":"x"},{"id":"bad2","scope":"read","expiresAt":"x"}]}"#.utf8)
        let keys = try XCTUnwrap(TripRelay.parseKeys(list))
        XCTAssertEqual(keys.map(\.id), ["cd34ef56", "ab12cd34"], "no-expiry first")
        XCTAssertNil(keys.first?.expiresAt)
        XCTAssertEqual(keys.last?.scope, .read)
        XCTAssertFalse(keys[0].expiresSoon(now: now))
        XCTAssertTrue(AssistantScopedKey(id: "x", scope: .read, expiresAt: now.addingTimeInterval(6 * 86_400)).expiresSoon(now: now))
        XCTAssertEqual(TripRelay.rotationDeletionPaths, ["/keys", "/activity", "/command", "/plan"])
    }

    func testConnectionLabelsStayLocalAndAreValidated() throws {
        let store = defaults()
        XCTAssertNil(AssistantKeyLabels.clean("   "))
        XCTAssertNil(AssistantKeyLabels.clean(String(repeating: "가", count: 21)))
        XCTAssertEqual(AssistantKeyLabels.clean(" 피클 "), "피클")
        AssistantKeyLabels.save("ab12cd34", label: "피클", period: .never, defaults: store)
        XCTAssertEqual(AssistantKeyLabels.label("ab12cd34", defaults: store), "피클")
        XCTAssertEqual(AssistantKeyLabels.period("ab12cd34", defaults: store), .never)
        XCTAssertEqual(AssistantKeyLabels.period("unknown", defaults: store), .quarter, "default 90 days")
        let body = try XCTUnwrap(TripRelay.keysBody(token: String(repeating: "S", count: 43), scope: .write, expiresAt: nil))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("피클"), "the label is never sent")
        AssistantKeyLabels.remove("ab12cd34", defaults: store)
        XCTAssertNil(AssistantKeyLabels.label("ab12cd34", defaults: store))
    }

    func testScopedSetupTextNeverCarriesTheMasterKey() {
        let master = String(repeating: "M", count: 43)
        let scoped = String(repeating: "S", count: 43)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let read = TripRelay.assistantSetupText(host: "relay.example.com", key: scoped, scope: .read, expiresAt: at(12), timeZone: zone)
        let write = TripRelay.assistantSetupText(host: "relay.example.com", key: scoped, scope: .write, expiresAt: at(12), timeZone: zone)
        for text in [read, write] {
            XCTAssertFalse(text.contains(master))
            XCTAssertTrue(text.contains("Bearer \(scoped)"))
            for part in ["https://relay.example.com/mcp", "https://relay.example.com/openapi.json", "GET /activity/summary?range=week|month", "plans (id, title, start, end)"] {
                XCTAssertTrue(text.contains(part), part)
            }
        }
        XCTAssertFalse(read.contains("POST /command"), "a read-only key gets no write instructions")
        XCTAssertFalse(read.contains("/tasks/claim"))
        XCTAssertTrue(write.contains("POST /tasks/claim") && write.contains("POST /tasks/result") && write.contains("every 10 minutes"))
        XCTAssertTrue(read.contains("read-only"))
        let forever = TripRelay.assistantSetupText(host: "relay.example.com", key: scoped, scope: .write, expiresAt: nil, timeZone: zone)
        XCTAssertTrue(forever.contains("does not expire"))
        XCTAssertFalse(forever.contains(master))
        for action in ["hideRecord", "mergeRecords", "updateRecordTime", "updateSchedule", "deleteSchedule", "updateMemo", "deleteMemo"] {
            XCTAssertTrue(write.contains(action), action)
        }
    }

    // MARK: - 하루 기록

    func testDayJSONCarriesPlansWithIDsAndHidesMergedRecords() throws {
        let plan = PlanRecord(title: "치과", span: TimeSpan(start: at(15), end: at(16)), categoryID: "activity")
        let other = PlanRecord(title: "다음 날", span: TimeSpan(start: at(15, day: 11), end: at(16, day: 11)), categoryID: "activity")
        let cover = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(8, 30), endedAt: at(18), source: .manual,
                                 modelVersion: ActivitySectionOverrideEngine.modelVersion, manuallyCorrected: true)
        let input = AssistantActivityInput(
            day: at(0), calendar: calendar, language: .korean, categories: [], steps: nil, plansScheduled: 1, plansCompleted: 0,
            actuals: [walk, work, cover], categoryTitles: [:],
            memos: [ActionMemo(occurredAt: at(12), kind: .idea, text: "점심")], stays: [], travel: [],
            registeredNames: [:], now: at(23), plans: [other, plan]
        )
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input, level: .summary))
        XCTAssertEqual(day.plans, [.init(id: plan.id.uuidString, title: "치과", start: "2026-11-10T15:00+09:00", end: "2026-11-10T16:00+09:00")])
        XCTAssertEqual(day.records.map(\.id), [cover.id.uuidString], "records under a merge cover are not repeated")
        XCTAssertFalse(day.memos.first?.id.isEmpty ?? true)
    }
}

// MARK: - 동작 등록부 (ACT1114A07)

extension AssistantCommandEditTests {
    private func operation(_ action: String, _ extra: [String: Any]) throws -> AssistantCommand.Action {
        try XCTUnwrap(batch([command("op", action, extra)]).commands.first?.action, "\(action) \(extra)")
    }

    private func isInvalid(_ action: String, _ extra: [String: Any]) throws -> Bool {
        try batch([command("op", action, extra)]).invalidIDs == ["op"]
    }

    /// 기기 저장소·가계부만 바꾼 동작의 「AI가 한 일」 항목.
    private func logEntry(_ action: AssistantCommand.Action, _ result: AssistantEditResult) -> AssistantLogEntry {
        var delta = AssistantEditDelta()
        delta.appChange = result.appChange
        delta.ledgerEntryID = result.ledgerEntryID
        delta.ledgerEntry = result.ledgerEntry
        delta.ledgerBefore = result.ledgerBefore
        delta.preferences = result.preferences.isEmpty ? nil : result.preferences
        return AssistantLogEntry(commandID: UUID().uuidString, kind: action.kind, appliedAt: .now, before: result.before, after: result.after, delta: delta)
    }

    private func emptyModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    /// 서버 등록부에서 뽑은 견본(`npm run actions`)과 앱의 동작 표가 이름·칸까지 같다.
    func testOperationTableMatchesTheServerRegistry() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/trip-relay/test/fixtures/actions.json")
        let server = try JSONDecoder().decode(AssistantActionManifest.self, from: Data(contentsOf: file)).actions
        let app = AssistantOperations.all.map { $0.spec }
        XCTAssertEqual(Set(server.map(\.action)), Set(app.map(\.name)))
        XCTAssertEqual(app.count, Set(app.map(\.name)).count, "이름이 겹치지 않는다")
        for action in server {
            XCTAssertEqual(AssistantOperations.spec(action.action).map { Set($0.fields) }, Set(action.fields), action.action)
        }
        for spec in app {
            XCTAssertFalse(spec.title(.korean).isEmpty)
            XCTAssertTrue(spec.guide.hasPrefix("\""), spec.name)
            XCTAssertNil(["format", "version", "id", "action", "taskId", "keyId", "source"].first(where: spec.fields.contains), spec.name)
        }
    }

    func testActionKindsKeepTheirStoredNamesAndOldLogsDecode() throws {
        XCTAssertEqual(AssistantActionKind.builtIn.count, 49)
        XCTAssertEqual(Set(AssistantActionKind.builtIn.map(\.rawValue)).count, 49)
        XCTAssertTrue(AssistantActionKind.builtIn.allSatisfy { AssistantActionKind(rawValue: $0.rawValue) == $0 })
        XCTAssertEqual(AssistantActionKind.deleteMemo.rawValue, "deleteMemo")
        XCTAssertEqual(AssistantActionToggles.key(.deleteMemo), "assistantAction.deleteMemo")
        XCTAssertEqual(AssistantActionKind(rawValue: "setFxRate"), .operation("setFxRate"))
        XCTAssertEqual(AssistantActionToggles.key(.operation("setFxRate")), "assistantAction.setFxRate")
        XCTAssertNil(AssistantActionKind(rawValue: "nope"))
        XCTAssertTrue(AssistantActionKind.allCases.contains(.operation("deleteLedgerTrip")))
        XCTAssertNil(AssistantActionKind.builtIn.first { AssistantOperations.spec($0.rawValue) != nil }, "예전 이름과 겹치지 않는다")
        XCTAssertTrue(AssistantActionTogglesView.kinds(deleting: true).contains(.operation("deleteLedgerTrip")))
        XCTAssertFalse(AssistantActionTogglesView.kinds(deleting: false).contains(.operation("deleteLedgerTrip")))
        XCTAssertTrue(AssistantActionTogglesView.kinds(deleting: false).contains(.deleteMemo))

        let json = { (kind: String) in
            Data(#"[{"id":"7E2C3F0A-7E1D-4F2A-9C77-1B9F0F0E0A11","commandID":"x","kind":"\#(kind)","appliedAt":0,"before":"","after":"","delta":{"plans":[],"memos":[],"actuals":[],"corrections":[],"addedSleepSpans":[],"removedSleepSpans":[]}}]"#.utf8)
        }
        XCTAssertEqual(try JSONDecoder().decode([AssistantLogEntry].self, from: json("addMemo")).first?.kind, .addMemo)
        XCTAssertEqual(try JSONDecoder().decode([AssistantLogEntry].self, from: json("setFxRate")).first?.kind, .operation("setFxRate"))
        let unknown = try XCTUnwrap(JSONDecoder().decode([AssistantLogEntry].self, from: json("laterAction")).first)
        XCTAssertEqual(unknown.kind.title(.korean), "laterAction", "모르는 동작이 든 로그도 읽는다")
        let again = try JSONDecoder().decode([AssistantLogEntry].self, from: JSONEncoder().encode([unknown]))
        XCTAssertEqual(again.first?.kind, .operation("laterAction"))
    }

    func testOperationsParseWithTheServerRulesAndCarryTheirKind() throws {
        let id = UUID().uuidString
        let parsed = try batch([
            command("f1", "setFxRate", ["currency": "USD", "krwPerUnit": 1_400, "keyId": "k1", "source": "mcp", "taskId": "t1", "extra": true]),
            command("f2", "setFxRate", ["currency": "KRW", "krwPerUnit": 1]),
            command("f3", "setFxRate", ["currency": "USD", "krwPerUnit": "1400"]),
            ["format": "bokki-command", "version": 2, "id": "f4", "action": "setFxRate", "currency": "USD", "krwPerUnit": 1_400],
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["f1"])
        XCTAssertEqual(parsed.invalidIDs, ["f2", "f3", "f4"])
        XCTAssertEqual(parsed.invalidInfo["f2"]?.kind, .operation("setFxRate"))
        let command = try XCTUnwrap(parsed.commands.first)
        XCTAssertEqual([command.keyID, command.source, command.taskID], ["k1", "mcp", "t1"])
        XCTAssertEqual(command.action.kind, .operation("setFxRate"))
        XCTAssertEqual(command.action, try operation("setFxRate", ["currency": "USD", "krwPerUnit": 1_400]), "모르는 칸은 버린다")
        XCTAssertEqual(command.action.existingChangeCount, 1)
        XCTAssertEqual(try operation("addLedgerTrip", ["name": "제주", "start": "2026-12-01"]).existingChangeCount, 0)

        XCTAssertNoThrow(try operation("classifyInboxItem", ["inboxId": id, "choice": "internal"]))
        XCTAssertTrue(try isInvalid("classifyInboxItem", ["inboxId": id, "choice": "maybe"]))
        XCTAssertTrue(try isInvalid("classifyInboxItem", ["inboxId": "x", "choice": "expense"]))
        XCTAssertNoThrow(try operation("setPaymentSource", ["name": "문자", "income": false]))
        XCTAssertNoThrow(try operation("setPaymentSource", ["name": "은행 앱", "remove": true]))
        XCTAssertTrue(try isInvalid("setPaymentSource", ["name": "은행 앱"]))
        XCTAssertTrue(try isInvalid("setPaymentSource", ["name": "은행 앱", "remove": true, "expense": true]))
        XCTAssertTrue(try isInvalid("setPaymentSource", ["name": "은행 앱", "expense": "yes"]))
        XCTAssertNoThrow(try operation("setSkipWords", ["add": ["광고"], "remove": ["자동이체"]]))
        XCTAssertTrue(try isInvalid("setSkipWords", [:]))
        XCTAssertTrue(try isInvalid("setSkipWords", ["add": ["a", "a"]]))
        XCTAssertTrue(try isInvalid("setSkipWords", ["add": [String(repeating: "x", count: 21)]]))
        XCTAssertTrue(try isInvalid("addLedgerTrip", ["name": "제주", "start": "2026-12-03", "end": "2026-12-01"]))
        XCTAssertTrue(try isInvalid("addLedgerTrip", ["name": "제주", "start": "2026-12-01", "members": ["@me"]]))
        XCTAssertNoThrow(try operation("updateLedgerTrip", ["tripId": "ledger-1", "members": [String]()]))
        XCTAssertNoThrow(try operation("updateLedgerTrip", ["tripId": "ledger-1", "autoSettlement": true]))
        XCTAssertTrue(try isInvalid("updateLedgerTrip", ["tripId": "ledger-1"]))
        XCTAssertTrue(try isInvalid("updateLedgerTrip", ["tripId": "ledger-1", "autoSettlement": true, "settlementKRW": 0]))
        XCTAssertTrue(try isInvalid("updateLedgerTrip", ["tripId": "ledger-1", "autoSettlement": false]))
        XCTAssertTrue(try isInvalid("deleteLedgerTrip", [:]))
    }

    func testOperationTogglesCountsLogAndSetupText() async throws {
        let store = defaults()
        let model = await emptyModel()
        let commands = try batch([
            command("r1", "setFxRate", ["currency": "USD", "krwPerUnit": 1_400]),
            command("w1", "setSkipWords", ["add": ["광고"]]),
        ])
        AssistantActionToggles.set(.operation("setSkipWords"), enabled: false, defaults: store)
        let applied = await model.applyAssistantCommands(commands, defaults: store)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results.map(\.applied), [true, false])
        XCTAssertEqual(outcome.results.last?.reason, "disabled")
        XCTAssertEqual([outcome.ledger, outcome.settings], [1, 0])
        XCTAssertEqual(outcome.entries.map(\.kind), [.operation("setFxRate")])
        XCTAssertEqual((store.dictionary(forKey: LedgerBook.manualRatesKey) as? [String: Double])?["USD"], 1_400)
        XCTAssertTrue(PaymentAlertSources.skipWords(store).isEmpty)
        XCTAssertEqual(AssistantBatchPolicy.changeCount(commands, defaults: store), 1, "꺼 둔 동작은 세지 않는다")

        let entry = try XCTUnwrap(outcome.entries.first)
        let undone = await model.undoAssistantEntry(entry, preferences: .test(store))
        XCTAssertTrue(undone)
        XCTAssertNil(store.object(forKey: LedgerBook.manualRatesKey))

        let text = TripRelay.assistantSetupText(host: "relay.example", key: "key")
        for spec in AssistantOperations.all.map { $0.spec } {
            XCTAssertTrue(text.contains("\"action\":\"\(spec.name)\",\"\(spec.fields[0])\""), spec.name)
        }
        XCTAssertFalse(TripRelay.assistantSetupText(host: "relay.example", key: "key", scope: .read).contains("setFxRate"))
    }

    // MARK: 1묶음 — 가계부

    func testFxRatePaymentSourcesAndSkipWordsApplyAndUndo() async throws {
        let store = defaults()
        let model = await emptyModel()
        let preferences = AssistantPreferenceStore.test(store)
        func run(_ action: String, _ extra: [String: Any]) async throws -> (AssistantCommand.Action, AssistantEditResult) {
            let action = try operation(action, extra)
            return (action, await model.applyAssistantAction(action, preferences: preferences))
        }
        func undo(_ pair: (AssistantCommand.Action, AssistantEditResult)) async -> Bool {
            model.userFacingError = nil
            return await model.undoAssistantEntry(logEntry(pair.0, pair.1), preferences: preferences)
        }
        func rates() -> [String: Double] { (store.dictionary(forKey: LedgerBook.manualRatesKey) as? [String: Double]) ?? [:] }

        let first = try await run("setFxRate", ["currency": "USD", "krwPerUnit": 1_400])
        XCTAssertNil(first.1.reason)
        XCTAssertEqual(rates(), ["USD": 1_400])
        let same = try await run("setFxRate", ["currency": "USD", "krwPerUnit": 1_400])
        XCTAssertEqual(same.1.reason, "no_change")
        let second = try await run("setFxRate", ["currency": "USD", "krwPerUnit": 1_450])
        XCTAssertTrue(second.1.before.contains("USD"))
        let stale = await undo(first)
        XCTAssertFalse(stale, "그 뒤 값이 바뀌었으면 되돌리지 않는다")
        let back = await undo(second)
        XCTAssertTrue(back)
        XCTAssertEqual(rates(), ["USD": 1_400])

        let texts = try await run("setPaymentSource", ["name": PaymentAlertSources.smsName, "income": false])
        XCTAssertNil(texts.1.reason)
        XCTAssertEqual(PaymentAlertSources.all(store).map { [$0.expense, $0.income] }, [[true, false]])
        XCTAssertFalse(PaymentAlertSources.allows(PaymentAlertSources.smsName, income: true, defaults: store))
        let fixed = try await run("setPaymentSource", ["name": PaymentAlertSources.smsName, "remove": true])
        XCTAssertEqual(fixed.1.reason, "not_editable")
        let missing = try await run("setPaymentSource", ["name": "은행 앱", "remove": true])
        XCTAssertEqual(missing.1.reason, "no_source")
        let app = try await run("setPaymentSource", ["name": "은행 앱", "expense": false])
        XCTAssertEqual(PaymentAlertSources.all(store).map(\.name), [PaymentAlertSources.smsName, "은행 앱"])
        let again = try await run("setPaymentSource", ["name": "은행 앱", "expense": false])
        XCTAssertEqual(again.1.reason, "no_change")
        let removed = try await run("setPaymentSource", ["name": "은행 앱", "remove": true])
        XCTAssertNil(removed.1.reason)
        XCTAssertEqual(PaymentAlertSources.all(store).map(\.name), [PaymentAlertSources.smsName])
        let restored = await undo(removed)
        XCTAssertTrue(restored)
        XCTAssertEqual(PaymentAlertSources.all(store).last.map { [$0.expense, $0.income] }, [false, true])
        let appUndone = await undo(app)
        XCTAssertTrue(appUndone)
        let textsUndone = await undo(texts)
        XCTAssertTrue(textsUndone)
        XCTAssertNil(store.object(forKey: PaymentAlertSources.key))

        let words = try await run("setSkipWords", ["add": ["광고", "자동이체"]])
        XCTAssertEqual(PaymentAlertSources.skipWords(store), ["광고", "자동이체"])
        let swapped = try await run("setSkipWords", ["add": ["충전"], "remove": ["광고"]])
        XCTAssertEqual(PaymentAlertSources.skipWords(store), ["자동이체", "충전"])
        XCTAssertEqual(swapped.1.before, "광고, 자동이체")
        let nothing = try await run("setSkipWords", ["remove": ["없는 낱말"]])
        XCTAssertEqual(nothing.1.reason, "no_change")
        let swappedUndone = await undo(swapped)
        XCTAssertTrue(swappedUndone)
        let wordsUndone = await undo(words)
        XCTAssertTrue(wordsUndone)
        XCTAssertTrue(PaymentAlertSources.skipWords(store).isEmpty)

        // 앱 상태에 스위치·낱말·환율이 실린다. 좌표나 번호는 없다.
        _ = try await run("setFxRate", ["currency": "JPY", "krwPerUnit": 9.5])
        _ = try await run("setSkipWords", ["add": ["광고"]])
        _ = try await run("setPaymentSource", ["name": "은행 앱", "income": false])
        let input = await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(15), calendar: calendar)
        let state = AssistantAppStateSync.make(input)
        XCTAssertEqual(state.settings.paymentSources, [.init(name: "은행 앱", expense: true, income: false)])
        XCTAssertEqual(state.settings.skipWords, ["광고"])
        XCTAssertEqual(state.settings.fxRates, ["USD": 1_400, "JPY": 9.5])
    }

    func testLedgerTripsAreCreatedEditedDeletedAndUndone() async throws {
        let store = defaults()
        let model = await emptyModel()
        let preferences = AssistantPreferenceStore.test(store)
        let book = preferences.ledger
        func run(_ action: String, _ extra: [String: Any]) async throws -> (AssistantCommand.Action, AssistantEditResult) {
            let action = try operation(action, extra)
            return (action, await model.applyAssistantAction(action, preferences: preferences))
        }
        func undo(_ pair: (AssistantCommand.Action, AssistantEditResult)) async -> Bool {
            model.userFacingError = nil
            return await model.undoAssistantEntry(logEntry(pair.0, pair.1), preferences: preferences)
        }

        let created = try await run("addLedgerTrip", ["name": "제주", "start": "2026-11-01", "end": "2026-11-03", "members": ["민아"]])
        XCTAssertNil(created.1.reason)
        let trip = try XCTUnwrap(book.trips.first)
        XCTAssertEqual([trip.name, trip.members.joined()], ["제주", "민아"])
        XCTAssertEqual(trip.start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        XCTAssertTrue(trip.id.hasPrefix("ledger-"))

        let unknown = try await run("updateLedgerTrip", ["tripId": "nope", "name": "부산"])
        XCTAssertEqual(unknown.1.reason, "no_trip")
        let edited = try await run("updateLedgerTrip", ["tripId": trip.id, "name": "부산", "members": ["민아", "준"], "settlementKRW": -30_000, "settlementDate": "2026-11-05"])
        XCTAssertNil(edited.1.reason)
        let saved = try XCTUnwrap(book.trip(trip.id))
        XCTAssertEqual([saved.name, saved.members.joined(separator: ",")], ["부산", "민아,준"])
        XCTAssertEqual(saved.settlementKRW, -30_000)
        XCTAssertNotNil(saved.settlementDate)
        let same = try await run("updateLedgerTrip", ["tripId": trip.id, "name": "부산"])
        XCTAssertEqual(same.1.reason, "no_change")
        let reversed = try await run("updateLedgerTrip", ["tripId": trip.id, "end": "2026-10-01"])
        XCTAssertEqual(reversed.1.reason, "end_before_start")
        let automatic = try await run("updateLedgerTrip", ["tripId": trip.id, "autoSettlement": true])
        XCTAssertNil(automatic.1.reason)
        XCTAssertNil(book.trip(trip.id)?.settlementKRW)
        XCTAssertNil(book.trip(trip.id)?.settlementDate)
        let stale = await undo(edited)
        XCTAssertFalse(stale, "그 뒤 장부가 바뀌었으면 되돌리지 않는다")
        let fixedAgain = await undo(automatic)
        XCTAssertTrue(fixedAgain)
        XCTAssertEqual(book.trip(trip.id)?.settlementKRW, -30_000)

        // 여행 지출: 장부가 있어야 하고, 몫은 동행에게만 나눈다.
        let noTrip = try await run("addExpense", ["amount": 12_000, "title": "저녁", "tripId": "nope"])
        XCTAssertEqual(noTrip.1.reason, "no_trip")
        let stranger = try await run("addExpense", ["amount": 12_000, "title": "저녁", "tripId": trip.id, "shareNames": ["모르는 사람"]])
        XCTAssertEqual(stranger.1.reason, "no_member")
        let dinner = try await run("addExpense", ["amount": 12_000, "title": "저녁", "tripId": trip.id, "shareNames": ["@me", "준"], "note": "둘이서", "date": "2026-11-02", "time": "19:00"])
        XCTAssertNil(dinner.1.reason)
        let entry = try XCTUnwrap(book.entries.first { $0.title == "저녁" })
        XCTAssertEqual([entry.tripID, entry.note, entry.shareNames?.joined(separator: ",")], [trip.id, "둘이서", "@me,준"])
        XCTAssertEqual(LedgerTripMath.sheet(saved, entries: book.entries).myCost, 6_000)

        let local = Calendar.autoupdatingCurrent
        let moved = try await run("updateExpense", ["entryId": entry.id.uuidString, "date": "2026-11-03", "time": "08:15", "note": "아침으로 고침", "shareNames": [String]()])
        XCTAssertNil(moved.1.reason)
        let changed = try XCTUnwrap(book.entries.first { $0.id == entry.id })
        XCTAssertEqual(local.dateComponents([.year, .month, .day, .hour, .minute], from: changed.occurredAt), DateComponents(year: 2026, month: 11, day: 3, hour: 8, minute: 15))
        XCTAssertEqual(changed.note, "아침으로 고침")
        XCTAssertNil(changed.shareNames, "빈 목록은 다 같이")
        let timeOnly = try await run("updateExpense", ["entryId": entry.id.uuidString, "time": "21:40"])
        XCTAssertNil(timeOnly.1.reason)
        let later = try XCTUnwrap(book.entries.first { $0.id == entry.id })
        XCTAssertEqual(local.dateComponents([.day, .hour, .minute], from: later.occurredAt), DateComponents(day: 3, hour: 21, minute: 40))
        let daily = try await run("updateExpense", ["entryId": entry.id.uuidString, "tripId": "none"])
        XCTAssertNil(daily.1.reason)
        XCTAssertNil(book.entries.first { $0.id == entry.id }?.tripID)
        let dailyUndone = await undo(daily)
        XCTAssertTrue(dailyUndone)
        XCTAssertEqual(book.entries.first { $0.id == entry.id }?.tripID, trip.id)
        XCTAssertTrue(try isInvalid("updateExpense", ["entryId": entry.id.uuidString, "time": "25:00"]))
        XCTAssertTrue(try isInvalid("addExpense", ["amount": 1, "title": "x", "shareNames": [String]()]))

        let deleted = try await run("deleteLedgerTrip", ["tripId": trip.id])
        XCTAssertNil(deleted.1.reason)
        XCTAssertNil(book.trip(trip.id))
        XCTAssertNotNil(book.entries.first { $0.id == entry.id }, "안의 기록은 남는다")
        let gone = try await run("deleteLedgerTrip", ["tripId": trip.id])
        XCTAssertEqual(gone.1.reason, "no_trip")
        let revived = await undo(deleted)
        XCTAssertTrue(revived)
        XCTAssertEqual(book.trip(trip.id)?.members, ["민아", "준"])

        let fresh = try await run("addLedgerTrip", ["name": "강릉", "start": "2026-12-10"])
        let freshID = try XCTUnwrap(book.trips.first { $0.name == "강릉" }?.id)
        let freshUndone = await undo(fresh)
        XCTAssertTrue(freshUndone)
        XCTAssertNil(book.trip(freshID), "만든 장부는 되돌리면 지운다")
    }

    func testInboxItemIsClassifiedLikeTheScreenChoiceAndUndone() async throws {
        let store = defaults()
        let model = await emptyModel()
        let preferences = AssistantPreferenceStore.test(store)
        let book = preferences.ledger
        PaymentInbox.record("체크카드 승인 12,300원 편의점", outcome: .unread, message: "읽지 못함", now: .now, defaults: store)
        PaymentInbox.record("안내 5,000원 충전", outcome: .unread, message: "읽지 못함", now: .now, defaults: store)
        let items = PaymentInbox.items(store)
        XCTAssertEqual(items.count, 2)

        let missing = await model.applyAssistantAction(try operation("classifyInboxItem", ["inboxId": UUID().uuidString, "choice": "expense"]), preferences: preferences)
        XCTAssertEqual(missing.reason, "no_inbox_item")

        let expense = try operation("classifyInboxItem", ["inboxId": items[0].id.uuidString, "choice": "expense"])
        let added = await model.applyAssistantAction(expense, preferences: preferences)
        XCTAssertNil(added.reason)
        XCTAssertEqual(PaymentInbox.items(store).first?.choice, .expense)
        XCTAssertEqual(PaymentInbox.items(store).first?.outcome, .added)
        XCTAssertEqual(book.entries.map(\.amount), [12_300])
        XCTAssertEqual(added.ledgerEntryID, book.entries.first?.id)

        // 「내부」는 이 글로 들어간 기록을 지운다. 되돌리면 기록도 글도 돌아온다.
        let inner = try operation("classifyInboxItem", ["inboxId": items[0].id.uuidString, "choice": "internal"])
        let internalResult = await model.applyAssistantAction(inner, preferences: preferences)
        XCTAssertNil(internalResult.reason)
        XCTAssertTrue(book.entries.isEmpty)
        XCTAssertEqual(PaymentInbox.items(store).first?.isInternal, true)
        XCTAssertEqual(internalResult.ledgerBefore?.amount, 12_300)
        let innerUndone = await model.undoAssistantEntry(logEntry(inner, internalResult), preferences: preferences)
        XCTAssertTrue(innerUndone)
        XCTAssertEqual(book.entries.map(\.amount), [12_300])
        XCTAssertEqual(PaymentInbox.items(store).first?.choice, .expense)
        let expenseUndone = await model.undoAssistantEntry(logEntry(expense, added), preferences: preferences)
        XCTAssertTrue(expenseUndone)
        XCTAssertTrue(book.entries.isEmpty)
        XCTAssertNil(PaymentInbox.items(store).first { $0.id == items[0].id }?.choice)

        let skip = try operation("classifyInboxItem", ["inboxId": items[1].id.uuidString, "choice": "ignore"])
        let skipped = await model.applyAssistantAction(skip, preferences: preferences)
        XCTAssertNil(skipped.reason)
        XCTAssertNil(PaymentInbox.items(store).first { $0.id == items[1].id }, "넣지 않기로 한 글은 목록에서 빠진다")
        let skipUndone = await model.undoAssistantEntry(logEntry(skip, skipped), preferences: preferences)
        XCTAssertTrue(skipUndone)
        XCTAssertNotNil(PaymentInbox.items(store).first { $0.id == items[1].id })
    }
}

/// 서버가 뽑아 둔 동작 목록(`server/trip-relay/test/fixtures/actions.json`).
private struct AssistantActionManifest: Decodable {
    struct Action: Decodable {
        let action: String
        let fields: [String]
    }

    let actions: [Action]
}
