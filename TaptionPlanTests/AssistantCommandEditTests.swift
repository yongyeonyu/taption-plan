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
        // 사용자가 켜기 전에는 꺼져 있는 동작(백업에서 복원)만 빼고 모두 켜져 있다.
        XCTAssertTrue(AssistantActionKind.allCases.allSatisfy { AssistantActionToggles.isEnabled($0, defaults: store) != (AssistantOperations.spec($0.rawValue)?.startsOff ?? false) })
        XCTAssertEqual(AssistantOperations.all.filter { $0.spec.startsOff }.map { $0.spec.name }, ["restoreFromBackup"])
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
        // ACT1114A07: 분류와 상태도 함께 나간다(중요·상위 루틴은 있을 때만).
        XCTAssertEqual(day.plans, [.init(
            id: plan.id.uuidString, title: "치과", start: "2026-11-10T15:00+09:00", end: "2026-11-10T16:00+09:00", categoryId: "activity", status: "planned"
        )])
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
            XCTAssertTrue(spec.guide.hasPrefix(spec.fields.isEmpty ? "}" : "\""), spec.name)
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
            XCTAssertTrue(text.contains("\"action\":\"\(spec.name)\"" + (spec.fields.first.map { ",\"\($0)\"" } ?? "}")), spec.name)
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

// MARK: - 2묶음 — 일정 (ACT1114A07)

extension AssistantCommandEditTests {
    private func run(_ model: AppModel, _ action: String, _ extra: [String: Any], store: UserDefaults) async throws -> (reason: String?, entry: AssistantLogEntry?) {
        let applied = await model.applyAssistantCommands(try batch([command("c-\(UUID().uuidString)", action, extra)]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        return (outcome.results.first?.reason, outcome.entries.first)
    }

    private func bareModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    func testSchedulesTakeCategoryImportantAndParentGoal() async throws {
        let store = defaults()
        let model = await bareModel()
        let goalStart = at(0, day: 9), goalEnd = at(0, day: 20)
        let goalID = try XCTUnwrap(model.addPlan(title: GoalRecordPolicy.displayTitle("운동"), categoryID: "activity", startAt: goalStart, duration: goalEnd.timeIntervalSince(goalStart)))
        XCTAssertNotNil(model.assistantParentGoal(goalID.uuidString))

        XCTAssertTrue(try batch([command("x", "addSchedule", ["title": "달리기", "start": "2026-11-12T07:00+09:00", "parentGoalId": "none"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "updateSchedule", ["planId": planID, "parentGoalId": "goal"])]).invalidIDs == ["x"])
        XCTAssertEqual(
            try batch([command("x", "updateSchedule", ["planId": planID, "important": true])]).commands.first?.action,
            .updateSchedule(target: .init(planID: planID, startTime: nil), title: nil, start: nil, end: nil, note: nil, extras: .init(important: true))
        )

        let unknown = try await run(model, "addSchedule", ["title": "달리기", "start": "2026-11-12T07:00+09:00", "categoryId": "nope"], store: store)
        XCTAssertEqual(unknown.reason, "unknown_category")
        let outside = try await run(model, "addSchedule", ["title": "달리기", "start": "2026-11-25T07:00+09:00", "parentGoalId": goalID.uuidString], store: store)
        XCTAssertEqual(outside.reason, "outside_goal")
        let noGoal = try await run(model, "addSchedule", ["title": "달리기", "start": "2026-11-12T07:00+09:00", "parentGoalId": UUID().uuidString], store: store)
        XCTAssertEqual(noGoal.reason, "no_goal")

        let added = try await run(model, "addSchedule", [
            "title": "달리기", "start": "2026-11-12T07:00+09:00", "end": "2026-11-12T08:00+09:00", "categoryId": "activity", "important": true, "parentGoalId": goalID.uuidString,
        ], store: store)
        XCTAssertNil(added.reason)
        let plan = try XCTUnwrap(model.snapshot.plans.first { $0.title == "달리기" })
        XCTAssertEqual(plan.parentID, goalID)
        XCTAssertTrue(plan.isImportant)
        XCTAssertEqual(plan.span.start, at(7, day: 12))

        let edited = try await run(model, "updateSchedule", ["planId": plan.id.uuidString, "important": false, "parentGoalId": "none"], store: store)
        XCTAssertNil(edited.reason)
        let detached = try XCTUnwrap(model.snapshot.plans.first { $0.id == plan.id })
        XCTAssertNil(detached.parentID)
        XCTAssertFalse(detached.isImportant)
        XCTAssertEqual(detached.span, plan.span, "시각은 그대로")
        let bad = try await run(model, "updateSchedule", ["planId": plan.id.uuidString, "categoryId": "nope"], store: store)
        XCTAssertEqual(bad.reason, "unknown_category")

        let undone = await model.undoAssistantEntry(try XCTUnwrap(edited.entry), preferences: .test(store))
        XCTAssertTrue(undone)
        let back = try XCTUnwrap(model.snapshot.plans.first { $0.id == plan.id })
        XCTAssertEqual(back.parentID, goalID)
        XCTAssertTrue(back.isImportant)
        let removed = await model.undoAssistantEntry(try XCTUnwrap(added.entry), preferences: .test(store))
        XCTAssertTrue(removed)
        XCTAssertFalse(model.snapshot.plans.contains { $0.title == "달리기" })
    }

    func testPlanQuickActionsCompletePostponeAndUndo() async throws {
        let store = defaults()
        let model = await bareModel()
        let start = Date.now.addingTimeInterval(2 * 3_600)
        let id = try XCTUnwrap(model.addPlan(title: "회의 준비", categoryID: "activity", startAt: start, duration: 1_800))
        let before = try XCTUnwrap(model.snapshot.plans.first { $0.id == id })

        XCTAssertTrue(try batch([command("x", "planQuickAction", ["planId": id.uuidString, "quickAction": "skip"])]).invalidIDs == ["x"])
        let missing = try await run(model, "planQuickAction", ["planId": UUID().uuidString, "quickAction": "complete"], store: store)
        XCTAssertEqual(missing.reason, "no_plan")
        let idle = try await run(model, "planQuickAction", ["planId": id.uuidString, "quickAction": "stop"], store: store)
        XCTAssertEqual(idle.reason, "not_running")

        let later = try await run(model, "planQuickAction", ["planId": id.uuidString, "quickAction": "postpone30"], store: store)
        XCTAssertNil(later.reason)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == id }?.span.start, before.span.start.addingTimeInterval(1_800))
        let moved = await model.undoAssistantEntry(try XCTUnwrap(later.entry), preferences: .test(store))
        XCTAssertTrue(moved)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == id }?.span, before.span)

        let done = try await run(model, "planQuickAction", ["planId": id.uuidString, "quickAction": "complete"], store: store)
        XCTAssertNil(done.reason)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == id }?.status, .completed)
        XCTAssertEqual(model.snapshot.actuals.filter { $0.planID == id }.count, 1, "계획한 시간만큼 한 것으로 남는다")
        let twice = try await run(model, "planQuickAction", ["planId": id.uuidString, "quickAction": "complete"], store: store)
        XCTAssertEqual(twice.reason, "no_change")
        let reopened = await model.undoAssistantEntry(try XCTUnwrap(done.entry), preferences: .test(store))
        XCTAssertTrue(reopened)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == id }?.status, .planned)
        XCTAssertTrue(model.snapshot.actuals.filter { $0.planID == id }.isEmpty)

        // 캘린더 고정 일정은 미루지 않는다.
        var fixed = PlanRecord(title: "고정", span: TimeSpan(start: start, end: start.addingTimeInterval(1_800)), categoryID: "activity")
        fixed.isFixed = true
        model.snapshot.plans.append(fixed)
        let refused = try await run(model, "planQuickAction", ["planId": fixed.id.uuidString, "quickAction": "moveToNextFree"], store: store)
        XCTAssertEqual(refused.reason, "not_editable")
    }

    func testTimedTripItemsAreAddedEditedDeletedAndUndone() async throws {
        let store = defaults()
        let model = await bareModel()
        let saved = await model.saveTravelTrip(TravelTrip(id: "trip-1", title: "여행", startDay: "2026-12-01", endDay: "2026-12-03"))
        XCTAssertTrue(saved)
        func items() -> [TravelTripItem] { model.snapshot.settings.travelTripItems ?? [] }
        let stamp = { (text: String) in AssistantCommandParser.instant(text) }

        XCTAssertTrue(try batch([command("x", "addTripItem", ["tripId": "trip-1", "title": "저녁", "start": "2026-12-01T19:00+09:00", "end": "2026-12-01T18:00+09:00"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "addTripItem", ["tripId": "trip-1", "title": "저녁", "start": "2026-12-01T19:00+09:00", "end": "2026-12-01T20:00+09:00", "kind": "party"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "updateTripItem", ["tripId": "trip-1", "itemId": "m-1"])]).invalidIDs == ["x"])
        XCTAssertEqual(AssistantOperations.offsetSeconds("2026-12-01T19:00+09:00"), 32_400)
        XCTAssertEqual(AssistantOperations.offsetSeconds("2026-12-01T19:00:00Z"), 0)
        XCTAssertEqual(AssistantOperations.offsetSeconds("2026-12-01T19:00-03:30"), -12_600)

        let noTrip = try await run(model, "addTripItem", ["tripId": "nope", "title": "저녁", "start": "2026-12-01T19:00+09:00", "end": "2026-12-01T20:00+09:00"], store: store)
        XCTAssertEqual(noTrip.reason, "no_trip")
        let added = try await run(model, "addTripItem", [
            "tripId": "trip-1", "title": "저녁", "start": "2026-12-01T19:00+09:00", "end": "2026-12-01T20:00+09:00", "kind": "meal", "note": "창가 자리",
        ], store: store)
        XCTAssertNil(added.reason)
        let item = try XCTUnwrap(items().first)
        XCTAssertEqual([item.tripID, item.title, item.kind, item.note ?? ""], ["trip-1", "저녁", "meal", "창가 자리"])
        XCTAssertEqual([item.start, item.end], [stamp("2026-12-01T19:00+09:00"), stamp("2026-12-01T20:00+09:00")])
        XCTAssertEqual(item.startOffsetSeconds, 32_400)
        let linked = try XCTUnwrap(item.planID)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == linked }?.title, "저녁", "일상 쪽 계획이 함께 생긴다")

        let missing = try await run(model, "updateTripItem", ["tripId": "trip-1", "itemId": "nope", "title": "x"], store: store)
        XCTAssertEqual(missing.reason, "no_trip_item")
        let same = try await run(model, "updateTripItem", ["tripId": "trip-1", "itemId": item.itemID, "title": "저녁"], store: store)
        XCTAssertEqual(same.reason, "no_change")
        let moved = try await run(model, "updateTripItem", ["tripId": "trip-1", "itemId": item.itemID, "title": "늦은 저녁", "start": "2026-12-01T20:30+09:00"], store: store)
        XCTAssertNil(moved.reason)
        let later = try XCTUnwrap(items().first)
        XCTAssertEqual(later.title, "늦은 저녁")
        XCTAssertEqual([later.start, later.end], [stamp("2026-12-01T20:30+09:00"), stamp("2026-12-01T21:30+09:00")], "시작만 옮기면 길이를 지킨다")
        XCTAssertEqual(model.snapshot.plans.first { $0.id == linked }?.span.start, later.start)
        let movedBack = await model.undoAssistantEntry(try XCTUnwrap(moved.entry), preferences: .test(store))
        XCTAssertTrue(movedBack)
        XCTAssertEqual(items().first?.start, item.start)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == linked }?.title, "저녁")

        let deleted = try await run(model, "deleteTripItem", ["tripId": "trip-1", "itemId": item.itemID], store: store)
        XCTAssertNil(deleted.reason)
        XCTAssertTrue(items().isEmpty)
        XCTAssertFalse(model.snapshot.plans.contains { $0.title == "저녁" })
        let gone = try await run(model, "deleteTripItem", ["tripId": "trip-1", "itemId": item.itemID], store: store)
        XCTAssertEqual(gone.reason, "no_trip_item")
        let revived = await model.undoAssistantEntry(try XCTUnwrap(deleted.entry), preferences: .test(store))
        XCTAssertTrue(revived)
        let again = try XCTUnwrap(items().first)
        XCTAssertEqual([again.itemID, again.title], [item.itemID, "저녁"])
        XCTAssertEqual(again.planID.flatMap { id in model.snapshot.plans.first { $0.id == id } }?.title, "저녁", "되살린 계획에 다시 이어진다")

        // 사진 주소(AIP1114A08): 허용한 사진 서버의 https 주소만, 되돌리면 뗀다.
        let photo = "https://upload.wikimedia.org/wikipedia/commons/a/ab/Sample.jpg"
        for bad in ["http://upload.wikimedia.org/a.jpg", "https://example.com/a.jpg", "https://user@upload.wikimedia.org/a.jpg", "https://upload.wikimedia.org:8443/a.jpg"] {
            XCTAssertTrue(try batch([command("x", "setTripItemPhoto", ["itemId": again.itemID, "photoUrl": bad])]).invalidIDs == ["x"], bad)
        }
        XCTAssertTrue(try batch([command("x", "setTripItemPhoto", ["itemId": again.itemID])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "setTripItemPhoto", ["itemId": again.itemID, "photoUrl": photo, "remove": true])]).invalidIDs == ["x"])
        let unknown = try await run(model, "setTripItemPhoto", ["itemId": "nope", "photoUrl": photo], store: store)
        XCTAssertEqual(unknown.reason, "no_trip_item")
        let pictured = try await run(model, "setTripItemPhoto", ["itemId": again.itemID, "photoUrl": photo, "credit": "Author, CC BY-SA 4.0"], store: store)
        XCTAssertNil(pictured.reason)
        XCTAssertEqual(TravelPhotoLink.link(again.itemID, defaults: store), .init(url: try XCTUnwrap(URL(string: photo)), credit: "Author, CC BY-SA 4.0"))
        let samePhoto = try await run(model, "setTripItemPhoto", ["itemId": again.itemID, "photoUrl": photo, "credit": "Author, CC BY-SA 4.0"], store: store)
        XCTAssertEqual(samePhoto.reason, "no_change")
        let unpictured = await model.undoAssistantEntry(try XCTUnwrap(pictured.entry), preferences: .test(store))
        XCTAssertTrue(unpictured)
        XCTAssertNil(TravelPhotoLink.link(again.itemID, defaults: store))

        AssistantActionToggles.set(.operation("deleteTripItem"), enabled: false, defaults: store)
        let off = try await run(model, "deleteTripItem", ["tripId": "trip-1", "itemId": item.itemID], store: store)
        XCTAssertEqual(off.reason, "disabled")
        XCTAssertEqual(items().count, 1)
    }
}

// MARK: - 3묶음 — 기록 (ACT1114A07)

extension AssistantCommandEditTests {
    private func send(_ model: AppModel, _ action: String, _ extra: [String: Any], store: UserDefaults) async throws -> (reason: String?, entry: AssistantLogEntry?) {
        let applied = await model.applyAssistantCommands(try batch([command("c-\(UUID().uuidString)", action, extra)]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        return (outcome.results.first?.reason, outcome.entries.first)
    }

    private func seeded(_ seed: TaptionDataSnapshot) async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: seed), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    func testMoreTravelModesAndMemoTimesParseApplyAndUndo() async throws {
        let store = defaults()
        var seed = TaptionDataSnapshot.empty
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: at(8, 30), end: at(9)), distanceMeters: 8_000, confidence: .medium, evidence: [])
        seed.travel = [ride]
        let model = await seeded(seed)
        XCTAssertEqual(["run", "cycling", "taxi", "ship", "other"].map(AssistantCommandParser.travelMode), [.running, .cycling, .taxi, .ship, nil])
        XCTAssertEqual([TravelMode.cycling, .ship, .running, .taxi].map(AssistantActivityBuilder.mode), ["cycling", "ship", "walk", "car"])
        let cycled = try await send(model, "setTravelMode", ["date": "2026-11-10", "moveId": ride.id.uuidString, "mode": "cycling"], store: store)
        XCTAssertNil(cycled.reason)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .cycling)
        let rideBack = await model.undoAssistantEntry(try XCTUnwrap(cycled.entry), preferences: .test(store))
        XCTAssertTrue(rideBack)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .car)

        // 메모: 글만, 때만, 둘 다.
        let local = Calendar.autoupdatingCurrent
        let written = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12, minute: 5)))
        let memoID = try XCTUnwrap(model.addMemo(text: "점심 약속", kind: .idea, categoryID: MemoTimelineEngine.categoryID, on: written))
        XCTAssertEqual(
            try batch([command("x", "updateMemo", ["memoId": memoID.uuidString, "time": "08:30"])]).commands.first?.action,
            .updateMemo(memoID: memoID.uuidString, text: nil, when: .init(minutes: 510))
        )
        XCTAssertTrue(try batch([command("x", "updateMemo", ["memoId": memoID.uuidString])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "updateMemo", ["memoId": memoID.uuidString, "time": "8시"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "updateMemo", ["memoId": memoID.uuidString, "date": "2026-13-01"])]).invalidIDs == ["x"])

        let timed = try await send(model, "updateMemo", ["memoId": memoID.uuidString, "time": "08:30"], store: store)
        XCTAssertNil(timed.reason)
        var memo = try XCTUnwrap(model.snapshot.memos.first { $0.id == memoID })
        XCTAssertEqual(memo.text, "점심 약속")
        XCTAssertEqual(local.dateComponents([.day, .hour, .minute], from: memo.occurredAt), DateComponents(day: 10, hour: 8, minute: 30))
        let same = try await send(model, "updateMemo", ["memoId": memoID.uuidString, "time": "08:30"], store: store)
        XCTAssertEqual(same.reason, "no_change")
        let moved = try await send(model, "updateMemo", ["memoId": memoID.uuidString, "date": "2026-11-12", "text": "저녁 약속"], store: store)
        XCTAssertNil(moved.reason)
        memo = try XCTUnwrap(model.snapshot.memos.first { $0.id == memoID })
        XCTAssertEqual(memo.text, "저녁 약속")
        XCTAssertEqual(local.dateComponents([.day, .hour, .minute], from: memo.occurredAt), DateComponents(day: 12, hour: 8, minute: 30), "날짜만 주면 시각은 그대로")
        let movedBack = await model.undoAssistantEntry(try XCTUnwrap(moved.entry), preferences: .test(store))
        XCTAssertTrue(movedBack)
        memo = try XCTUnwrap(model.snapshot.memos.first { $0.id == memoID })
        XCTAssertEqual(memo.text, "점심 약속")
        XCTAssertEqual(local.component(.day, from: memo.occurredAt), 10)
    }

    func testManualRecordsAreDeletedAndRecordsLinkToPlans() async throws {
        let store = defaults()
        var seed = TaptionDataSnapshot.empty
        let mine = ActualRecord(planID: nil, title: "산책", categoryID: "activity", startedAt: at(10), endedAt: at(11), source: .manual)
        let sensed = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(13), endedAt: at(15), source: .location)
        let plan = PlanRecord(title: "보고서", span: TimeSpan(start: at(13), end: at(16)), categoryID: "work")
        let far = PlanRecord(title: "다음 날 일정", span: TimeSpan(start: at(13, day: 11), end: at(16, day: 11)), categoryID: "work")
        seed.actuals = [mine, sensed]
        seed.plans = [plan, far]
        let model = await seeded(seed)

        XCTAssertTrue(try batch([command("x", "deleteManualRecord", ["recordId": "r1"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "linkRecordToPlan", ["recordId": mine.id.uuidString])]).invalidIDs == ["x"])
        let automatic = try await send(model, "deleteManualRecord", ["recordId": sensed.id.uuidString], store: store)
        XCTAssertEqual(automatic.reason, "not_editable", "자동 기록은 지우지 않는다")
        let missing = try await send(model, "deleteManualRecord", ["recordId": UUID().uuidString], store: store)
        XCTAssertEqual(missing.reason, "no_record")
        let deleted = try await send(model, "deleteManualRecord", ["recordId": mine.id.uuidString], store: store)
        XCTAssertNil(deleted.reason)
        XCTAssertFalse(model.snapshot.actuals.contains { $0.id == mine.id })
        XCTAssertTrue(model.snapshot.settings.suppressedActualIDs.contains(mine.id))
        XCTAssertEqual(deleted.entry?.kind, .operation("deleteManualRecord"))
        let restored = await model.undoAssistantEntry(try XCTUnwrap(deleted.entry), preferences: .test(store))
        XCTAssertTrue(restored)
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == mine.id }?.title, "산책")
        XCTAssertFalse(model.snapshot.settings.suppressedActualIDs.contains(mine.id), "되살린 기록이 다시 가려지지 않는다")

        let noPlan = try await send(model, "linkRecordToPlan", ["recordId": sensed.id.uuidString, "planId": UUID().uuidString], store: store)
        XCTAssertEqual(noPlan.reason, "no_plan")
        let apart = try await send(model, "linkRecordToPlan", ["recordId": sensed.id.uuidString, "planId": far.id.uuidString], store: store)
        XCTAssertEqual(apart.reason, "not_linkable", "시간이 겹치지 않으면 잇지 않는다")
        XCTAssertNil(model.userFacingError, "실패는 AI 결과로만 알린다")
        let linked = try await send(model, "linkRecordToPlan", ["recordId": sensed.id.uuidString, "planId": plan.id.uuidString], store: store)
        XCTAssertNil(linked.reason)
        XCTAssertEqual(model.snapshot.actuals.first { $0.id == sensed.id }?.planID, plan.id)
        let twice = try await send(model, "linkRecordToPlan", ["recordId": sensed.id.uuidString, "planId": plan.id.uuidString], store: store)
        XCTAssertEqual(twice.reason, "no_change")
        let unlinked = await model.undoAssistantEntry(try XCTUnwrap(linked.entry), preferences: .test(store))
        XCTAssertTrue(unlinked)
        XCTAssertNil(model.snapshot.actuals.first { $0.id == sensed.id }?.planID)
    }

    func testBoardingCandidatesAreSharedWithoutCoordinatesAndResolved() async throws {
        let store = defaults()
        var seed = TaptionDataSnapshot.empty
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: at(8, 30), end: at(9)), distanceMeters: 8_000, confidence: .medium, evidence: [])
        seed.travel = [ride]
        let model = await seeded(seed)
        let candidate = TransitBoardingCandidate(
            id: "stop-key-1", placeID: "stop-1", name: "시험 정류장", kind: .busStop, point: GeoPoint(latitude: 1.25, longitude: 2.5, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10),
            span: TimeSpan(start: at(8, 25), end: at(8, 30)), dwellDuration: 300, source: .catalog, travelSegmentIDs: [ride.id]
        )
        AssistantBoardingCandidates.current = [candidate]
        addTeardownBlock { @MainActor in AssistantBoardingCandidates.current = [] }
        let publicID = AssistantBoardingCandidates.publicID(candidate)
        XCTAssertEqual(publicID.count, 16)
        XCTAssertFalse(publicID.contains("stop"))

        // 앱 상태: 장소 이름 공유 수준에서만, 좌표 없이.
        let preferences = AssistantPreferenceStore.test(store)
        var input = await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(15), calendar: calendar)
        input.shareLevel = .summary
        XCTAssertNil(AssistantAppStateSync.make(input).boarding)
        input.shareLevel = .visits
        let state = AssistantAppStateSync.make(input)
        XCTAssertEqual(state.boarding, [.init(id: publicID, name: "시험 정류장", kind: "busStop", mode: "bus", start: "2026-11-10T08:25+09:00", end: "2026-11-10T08:30+09:00")])
        let body = String(decoding: try XCTUnwrap(AssistantAppStateSync.body(state)), as: UTF8.self)
        XCTAssertFalse(body.contains("1.25") || body.contains("stop-1") || body.contains("stop-key-1"))

        XCTAssertTrue(try batch([command("x", "resolveBoarding", ["candidateId": "stop-key-1", "decision": "confirm"])]).invalidIDs == ["x"])
        XCTAssertTrue(try batch([command("x", "resolveBoarding", ["candidateId": publicID, "decision": "maybe"])]).invalidIDs == ["x"])
        let unknown = try await send(model, "resolveBoarding", ["candidateId": "0123456789abcdef", "decision": "confirm"], store: store)
        XCTAssertEqual(unknown.reason, "no_candidate")

        let confirmed = try await send(model, "resolveBoarding", ["candidateId": publicID, "decision": "confirm"], store: store)
        XCTAssertNil(confirmed.reason)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .bus)
        XCTAssertEqual(model.snapshot.settings.transitBoardingDecisions.map(\.candidateKey), ["stop-key-1"])
        XCTAssertTrue(AssistantBoardingCandidates.current.isEmpty, "답한 후보는 목록에서 빠진다")
        let undone = await model.undoAssistantEntry(try XCTUnwrap(confirmed.entry), preferences: .test(store))
        XCTAssertTrue(undone)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .car)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)

        AssistantBoardingCandidates.current = [candidate]
        let rejected = try await send(model, "resolveBoarding", ["candidateId": publicID, "decision": "reject"], store: store)
        XCTAssertNil(rejected.reason)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .car)
        XCTAssertNil(model.snapshot.settings.transitBoardingDecisions.first?.mode, "거절은 수단 없이 남는다")
        let back = await model.undoAssistantEntry(try XCTUnwrap(rejected.entry), preferences: .test(store))
        XCTAssertTrue(back)
        XCTAssertTrue(model.snapshot.settings.transitBoardingDecisions.isEmpty)
    }
}

// MARK: - 4묶음 — 설정 표 (ACT1114A07)

extension AssistantCommandEditTests {
    func testMoreDisplayOptionsSettingsScreensAndKakaoMap() async throws {
        let store = defaults()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let preferences = AssistantPreferenceStore.test(store)
        func entry(_ kind: AssistantActionKind, _ result: AssistantEditResult) -> AssistantLogEntry {
            var delta = AssistantEditDelta()
            delta.preferences = result.preferences.isEmpty ? nil : result.preferences
            delta.appChange = result.appChange
            return AssistantLogEntry(commandID: UUID().uuidString, kind: kind, appliedAt: .now, before: result.before, after: result.after, delta: delta)
        }

        let parsed = try batch([
            command("d1", "setDisplayOption", ["option": "sidebar", "enabled": false]),
            command("d2", "setDisplayOption", ["option": "vehicles", "enabled": false]),
            command("d3", "setDisplayOption", ["option": "memos", "enabled": false]),
            command("s1", "setSetting", ["setting": "memoDisplay", "value": "located"]),
            command("s2", "setSetting", ["setting": "memoDisplay", "value": "none"]),
            command("o1", "openScreen", ["screen": "dayCard"]),
            command("o2", "openScreen", ["screen": "aiRules"]),
            command("o3", "openScreen", ["screen": "backup"]),
            command("k1", "setMapStyle", ["mapStyle": "kakao"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["d3", "s2", "o3"])
        XCTAssertEqual(parsed.commands.map(\.action), [
            .setDisplayOption(.sidebar, enabled: false), .setDisplayOption(.vehicles, enabled: false), .setSetting(.memoDisplay, value: "located"),
            .openScreen(.dayCard), .openScreen(.aiRules), .setMapStyle(.kakao),
        ])
        XCTAssertEqual(AssistantDisplayOption.sidebar.defaultsKey, "mapHomeSidebarVisible")
        XCTAssertEqual(AssistantDisplayOption.vehicles.defaultsKey, MapHomeStickmanAction.vehicleDisplayKey)
        XCTAssertEqual(AssistantSetting.memoDisplay.key, "mapHomeMemoDisplay")
        XCTAssertFalse(AssistantScreen.allCases.contains { $0.title(.korean).isEmpty })

        let hidden = await model.applyAssistantAction(.setDisplayOption(.sidebar, enabled: false), preferences: preferences)
        XCTAssertNil(hidden.reason)
        XCTAssertEqual(store.object(forKey: "mapHomeSidebarVisible") as? Bool, false)
        let shown = await model.undoAssistantEntry(entry(.setDisplayOption, hidden), preferences: preferences)
        XCTAssertTrue(shown)
        XCTAssertEqual(store.object(forKey: "mapHomeSidebarVisible") as? Bool, true)

        let memos = await model.applyAssistantAction(.setSetting(.memoDisplay, value: "located"), preferences: preferences)
        XCTAssertNil(memos.reason)
        XCTAssertEqual(store.string(forKey: "mapHomeMemoDisplay"), MapHomeMemoDisplayMode.located.rawValue)
        let same = await model.applyAssistantAction(.setSetting(.memoDisplay, value: "located"), preferences: preferences)
        XCTAssertEqual(same.reason, "no_change")
        let cleared = await model.undoAssistantEntry(entry(.setSetting, memos), preferences: preferences)
        XCTAssertTrue(cleared)
        XCTAssertNil(store.object(forKey: "mapHomeMemoDisplay"), "정하기 전으로 돌아간다")

        let rules = await model.applyAssistantAction(.openScreen(.aiRules), preferences: preferences)
        XCTAssertNil(rules.reason)
        XCTAssertEqual(preferences.screens.take(), .aiRules)

        // 카카오 지도는 키가 든 빌드에서만 바뀐다.
        let kakao = await model.applyAssistantAction(.setMapStyle(.kakao), preferences: preferences)
        if KakaoMapAvailability.isAvailable {
            XCTAssertNil(kakao.reason)
            XCTAssertEqual(model.snapshot.settings.mapDisplayStyle, .kakao)
        } else {
            XCTAssertEqual(kakao.reason, "not_available")
            XCTAssertNotEqual(model.snapshot.settings.mapDisplayStyle, .kakao)
        }

        let input = await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(15), calendar: calendar)
        XCTAssertEqual(AssistantAppStateSync.make(input).settings.display.keys.sorted(), ["mapFootprints", "mapPhotos", "mapRoutes", "sidebar", "vehicles"])
        XCTAssertEqual(AssistantActionKind.setSetting.title(.english), "Change app settings (pay, tolls, weather, alerts…)")
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
