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
