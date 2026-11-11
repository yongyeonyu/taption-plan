import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// REV1110A06 리뷰 수정: 주 키 바꾸기, 공유 수준 낮추기, 틀린 명령, 서버와 같은 한도, 말풍선 문법,
/// 자동 기록 되돌리기, PIN 지우기, 명령 결과 장부.
@MainActor
final class AssistantReviewFixTests: XCTestCase {
    private let host = "relay.example.com"
    private let master = String(repeating: "M", count: 21) + String(repeating: "m", count: 22)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantReviewFixTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func environment(
        _ secrets: AssistantSecretStore, _ store: UserDefaults, cleared: Counter? = nil, status: @escaping (URLRequest) -> Int = { _ in 201 }
    ) -> AssistantRegistration.Environment {
        Phase3RelayStub.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase3RelayStub.self]
        return AssistantRegistration.Environment(
            secrets: secrets, defaults: store, session: URLSession(configuration: configuration), host: host, clearConnections: { cleared?.value += 1 }
        )
    }

    private final class Counter { var value = 0 }

    /// 등록과 바꾸기를 마친 설치.
    private func readyEnvironment(_ store: UserDefaults, status: @escaping (URLRequest) -> Int) -> AssistantRegistration.Environment {
        store.set(AssistantRegistration.rotationTag, forKey: AssistantRegistration.rotationKey)
        store.set(AssistantKeyStore.keyID(master), forKey: AssistantRegistration.registeredKey)
        return environment(AssistantMemorySecrets([.master: master]), store, status: status)
    }

    private func command(_ id: String, _ action: String, _ extra: [String: Any]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": action, "keyId": "aaaa1111", "source": "rest"].merging(extra) { _, new in new }
    }

    private func batch(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(12), calendar: calendar))
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func json(_ value: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self) }

    // MARK: - 주 키 바꾸기 (1, 15)

    func testRotationStopsWhenADeleteIsRefused() async {
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: master])
        let env = environment(secrets, store) { $0.httpMethod == "DELETE" && $0.url?.path == "/activity" ? 401 : 201 }
        let rotated = await AssistantRegistration.rotate(env)
        XCTAssertFalse(rotated, "a 401 on delete is not success")
        XCTAssertEqual(secrets.read(.master), master)
        XCTAssertNotNil(secrets.read(.pendingMaster))
        XCTAssertNil(store.string(forKey: AssistantRegistration.rotationKey))
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /register", "POST /register", "DELETE /keys", "DELETE /activity"])
    }

    func testRotationNeedsTheOldMasterRegisteredBeforeDeleting() async {
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: master])
        let old = master
        let env = environment(secrets, store) { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(old)" && $0.url?.path == "/register" ? 500 : 201 }
        let rotated = await AssistantRegistration.rotate(env)
        XCTAssertFalse(rotated)
        XCTAssertEqual(secrets.read(.master), master)
        XCTAssertFalse(Phase3RelayStub.requests.contains { $0.method == "DELETE" }, "nothing is deleted with an unregistered key")
    }

    func testRotationResumesWithTheSameNewKeyAndSkipsAKeyThatCanNeverBeAMaster() async throws {
        let store = defaults()
        let pending = String(repeating: "P", count: 21) + String(repeating: "p", count: 22)
        let secrets = AssistantMemorySecrets([.master: master, .pendingMaster: pending])
        let old = master
        // 예전 키가 409(다른 목적으로 쓰인 키)면 주 키 자료가 있을 수 없어 지우기를 건너뛴다.
        let env = environment(secrets, store) { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(old)" ? 409 : 200 }
        let rotated = await AssistantRegistration.rotate(env)
        XCTAssertTrue(rotated)
        XCTAssertEqual(secrets.read(.master), pending, "an interrupted rotation continues with the key made earlier")
        XCTAssertNil(secrets.read(.pendingMaster))
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /register", "POST /register"])
        XCTAssertTrue(AssistantRegistration.isReady(env))
    }

    func testUploadsAndCommandsPauseWhileTheMasterIsRotating() {
        XCTAssertTrue(AssistantRelayGate.begin())
        XCTAssertTrue(AssistantRelayGate.beginRotation())
        XCTAssertFalse(AssistantRelayGate.begin(), "no new upload starts with the old key")
        XCTAssertFalse(AssistantRelayGate.beginRotation(), "a second rotation is not started")
        AssistantRelayGate.end()
        AssistantRelayGate.endRotation()
        XCTAssertTrue(AssistantRelayGate.begin())
        AssistantRelayGate.end()
    }

    // MARK: - 공유 수준 (2)

    func testLoweringTheShareLevelDeletesServerDataBeforeUploadingAgain() async {
        XCTAssertTrue(AssistantShareLevel.isDowngrade(from: .visits, to: .summary))
        XCTAssertTrue(AssistantShareLevel.isDowngrade(from: .summary, to: .off))
        XCTAssertFalse(AssistantShareLevel.isDowngrade(from: .summary, to: .visits))
        XCTAssertFalse(AssistantShareLevel.isDowngrade(from: .visits, to: .visits))

        let store = defaults()
        store.set(AssistantShareLevel.summary.rawValue, forKey: AssistantShareLevel.defaultsKey)
        AssistantActivityUploadGate.markSent([AssistantActivityDay.empty(date: "2026-11-01")], defaults: store)
        AssistantActivitySync.requestClear(defaults: store)
        XCTAssertTrue(AssistantActivityUploadGate.sentHashes(store).isEmpty, "every day is uploaded again at the new level")
        let model = await makeModel()

        let failing = readyEnvironment(store) { _ in 500 }
        await AssistantActivitySync.run(model: model, defaults: store, env: failing)
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["DELETE /activity"], "nothing is uploaded until the old days are gone")
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "the delete is retried next time")

        let working = readyEnvironment(store) { $0.httpMethod == "DELETE" ? 204 : 201 }
        await AssistantActivitySync.run(model: model, defaults: store, env: working)
        XCTAssertEqual(Phase3RelayStub.requests.first?.summary, "DELETE /activity")
        XCTAssertEqual(Phase3RelayStub.requests.first?.token, master)
        XCTAssertFalse(store.bool(forKey: AssistantActivitySync.pendingClearKey))
    }

    // MARK: - 명령 읽기 (5, 6)

    func testOneMalformedCommandDoesNotBlockTheQueue() throws {
        let parsed = try batch([
            command("ok1", "addMemo", ["text": "하나"]),
            command("bad-order", "updateTripStop", ["stopId": UUID().uuidString, "order": "first"]),
            command("bad-enabled", "setDisplayOption", ["option": "mapPhotos", "enabled": "yes"]),
            command("bad-lat", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "latitude": "37.5", "longitude": 126.9]),
            command("bad-ids", "mergeRecords", ["date": "2026-11-10", "recordIds": "a,b"]),
            command("bad-version", "addMemo", ["text": "둘", "version": "1"]),
            ["id": 7, "action": "addMemo"],
            command("ok2", "addMemo", ["text": "셋"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["ok1", "ok2"], "good commands still arrive")
        XCTAssertEqual(parsed.invalidIDs, ["bad-order", "bad-enabled", "bad-lat", "bad-ids", "bad-version"], "each bad one is reported, not dropped")
    }

    func testParserLimitsMatchTheServer() throws {
        let id = UUID().uuidString
        let long = String(repeating: "가", count: 2_000)
        let parsed = try batch([
            command("o1", "updateTripStop", ["stopId": id, "order": 999]),
            command("o2", "updateTripStop", ["stopId": id, "order": 1_000]),
            command("o3", "updateTripStop", ["stopId": id, "order": -1]),
            command("t1", "addTripStop", ["title": "경복궁", "date": "2026-11-12"]),
            command("t2", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "latitude": 37.58]),
            command("t3", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "lat": 37.58, "lng": 126.98, "tripId": "trip-1"]),
            command("g1", "updateGoal", ["goalId": id, "categoryId": "study"]),
            command("g2", "updateGoal", ["goalId": id, "start": "2026-12-02", "end": "2026-12-01"]),
            command("m1", "updateMemo", ["memoId": id, "text": long]),
            command("m2", "updateMemo", ["memoId": id, "text": long + "가"]),
            command("n1", "updateSchedule", ["planId": id, "note": long]),
            command("n2", "updateSchedule", ["planId": id, "note": long + "가"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["o1", "t1", "t3", "g1", "m1", "n1"])
        XCTAssertEqual(parsed.invalidIDs, ["o2", "o3", "t2", "g2", "m2", "n2"])
        XCTAssertEqual(parsed.commands[1].action, .addTripStop(title: "경복궁", day: at(0, day: 12), coordinate: nil, status: nil, tripID: nil))
        XCTAssertEqual(parsed.commands[2].action, .addTripStop(
            title: "경복궁", day: at(0, day: 12), coordinate: AssistantCoordinate(latitude: 37.58, longitude: 126.98), status: nil, tripID: "trip-1"
        ))
        XCTAssertEqual(parsed.commands[3].action, .updateGoal(goalID: id, title: nil, start: nil, end: nil, categoryID: "study"))
    }

    func testSetupTextUsesTheServerValues() {
        let text = TripRelay.assistantSetupText(host: host, key: String(repeating: "A", count: 43), timeZone: calendar.timeZone)
        for part in ["automatic|korean|english|ja|", "\"setTheme\",\"theme\":\"classic|navy|purple|brown|ink\"", "\"setBubble\"", "set_bubble", "order 0 to 999", "background refresh"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertFalse(text.contains("ko|en|"), "the server rejects ko/en/auto")
        for language in AppLanguagePreference.allCases { XCTAssertNotNil(AssistantCommandParser.language(language.rawValue), language.rawValue) }
    }

    // MARK: - 반영 (6, 9, 18, 20)

    func testTripStopWithoutCoordinatesIsLookedUpAndJoinsItsTrip() async throws {
        let store = defaults()
        let model = await makeModel()
        let live = AssistantPlaceSearch.find
        addTeardownBlock { @MainActor in AssistantPlaceSearch.find = live }
        AssistantPlaceSearch.find = { _, _ in nil }
        let missing = await model.applyAssistantCommands(try batch([command("a", "addTripStop", ["title": "어딘가", "date": "2026-11-12"])]), defaults: store)
        XCTAssertEqual(missing?.results, [.init(id: "a", applied: false, reason: "place_not_found")])

        AssistantPlaceSearch.find = { _, _ in AssistantCoordinate(latitude: 37.58, longitude: 126.98) }
        let unknown = await model.applyAssistantCommands(
            try batch([command("b", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "tripId": "nope"])]), defaults: store
        )
        XCTAssertEqual(unknown?.results, [.init(id: "b", applied: false, reason: "no_trip")])

        model.snapshot.settings.travelTripItems = [TravelTripItem(
            tripID: "t1", itemID: "i1", kind: "sight", title: "남산", start: at(10), end: at(12), startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil
        )]
        let added = await model.applyAssistantCommands(
            try batch([command("c", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "tripId": "t1"])]), defaults: store
        )
        XCTAssertEqual(added?.results.map(\.applied), [true])
        let stop = try XCTUnwrap(model.snapshot.settings.travelPlanStops.first)
        XCTAssertEqual(stop.tripID, "t1")
        XCTAssertEqual(stop.latitude, 37.58)
    }

    func testGoalCategoryUpdateAndGoalsAreOutOfReachOfScheduleActions() async throws {
        let store = defaults()
        let model = await makeModel()
        let goal = PlanRecord(title: "루틴: 운동", span: TimeSpan(start: at(0), end: at(0, day: 20)), categoryID: "exercise")
        model.snapshot.plans = [goal]
        let category = try XCTUnwrap(model.snapshot.categories.first { $0.id != "unconfirmed" && $0.id != "exercise" }?.id)
        let updated = await model.applyAssistantCommands(
            try batch([command("g", "updateGoal", ["goalId": goal.id.uuidString, "categoryId": category])]), defaults: store
        )
        XCTAssertEqual(updated?.results, [.init(id: "g", applied: true, reason: nil)])
        XCTAssertEqual(model.snapshot.plans.first?.categoryID, category)

        AssistantActionToggles.set(.deleteGoal, enabled: false, defaults: store)
        AssistantActionToggles.set(.updateGoal, enabled: false, defaults: store)
        let blocked = await model.applyAssistantCommands(try batch([
            command("d", "deleteSchedule", ["planId": goal.id.uuidString]),
            command("u", "updateSchedule", ["planId": goal.id.uuidString, "title": "바꿈"]),
        ]), defaults: store)
        XCTAssertEqual(blocked?.results.map(\.reason), ["is_goal", "is_goal"], "the schedule actions cannot touch a routine")
        XCTAssertEqual(model.snapshot.plans.map(\.id), [goal.id])
    }

    func testDeletingARoutineCountsItsChildrenTowardTheConfirmRule() throws {
        var plans: [PlanRecord] = []
        var items: [[String: Any]] = []
        for index in 0..<3 {
            let goal = PlanRecord(title: "루틴: \(index)", span: TimeSpan(start: at(0), end: at(0, day: 20)), categoryID: "exercise")
            plans.append(goal)
            for hour in 0..<7 {
                plans.append(PlanRecord(title: "하위", span: TimeSpan(start: at(hour), end: at(hour + 1)), categoryID: "exercise", parentID: goal.id))
            }
            items.append(command("d\(index)", "deleteGoal", ["goalId": goal.id.uuidString]))
        }
        let parsed = try batch(items)
        let store = defaults()
        XCTAssertEqual(AssistantBatchPolicy.changeCount(parsed, defaults: store), 3, "without the plans only the routines are counted")
        XCTAssertEqual(AssistantBatchPolicy.changeCount(parsed, defaults: store, plans: plans), 24)
        XCTAssertTrue(AssistantBatchPolicy.needsConfirmation(parsed, defaults: store, plans: plans))
    }

    func testMemoOverTheStorageLimitIsRejectedWithoutAScreenError() async throws {
        let store = defaults()
        let model = await makeModel()
        let outcome = await model.applyAssistantCommands(
            try batch([command("m", "addMemo", ["text": String(repeating: "가", count: 1_001)])]), defaults: store
        )
        XCTAssertEqual(outcome?.results, [.init(id: "m", applied: false, reason: "memo_too_long")])
        XCTAssertNil(model.userFacingError)
    }

    func testSettingEntriesShowScreenNamesNotStoredValues() async throws {
        let store = defaults()
        let model = await makeModel()
        let outcome = await model.applyAssistantCommands(try batch([
            command("s", "setMapStyle", ["mapStyle": "mapLibreInk"]),
            command("o", "setDisplayOption", ["option": "mapPhotos", "enabled": false]),
        ]), defaults: store)
        let texts = (outcome?.entries ?? []).flatMap { [$0.before, $0.after] }
        XCTAssertEqual(texts.count, 4)
        for text in texts {
            XCTAssertFalse(text.contains("mapLibre") || text.contains("mapPhotos") || text.contains("true") || text.contains("false"), text)
        }
    }

    // MARK: - 되돌리기 (12)

    func testUndoDoesNotWriteAStaleCopyOverAnAutomaticRecord() async throws {
        let store = defaults()
        let model = await makeModel()
        let running = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(9), endedAt: nil, source: .location, evidence: ["사무실"])
        model.snapshot.actuals = [running]
        let applied = await model.applyAssistantCommands(try batch([
            command("e", "updateActivity", ["date": "2026-11-10", "recordId": running.id.uuidString, "title": "회의"]),
        ]), defaults: store)
        let entry = try XCTUnwrap(applied?.entries.first)
        XCTAssertEqual(model.snapshot.actuals.first?.title, "회의")
        // 그 뒤 센서가 기록을 끝내고 근거를 더했다.
        let index = try XCTUnwrap(model.snapshot.actuals.firstIndex { $0.id == running.id })
        model.snapshot.actuals[index].endedAt = at(11)
        model.snapshot.actuals[index].evidence = ["사무실", "떠남"]

        let undone = await model.undoAssistantEntry(entry, preferences: .test(store))
        XCTAssertTrue(undone)
        let record = try XCTUnwrap(model.snapshot.actuals.first { $0.id == running.id })
        XCTAssertEqual(record.title, "업무", "the AI's change is undone")
        XCTAssertEqual(record.endedAt, at(11), "the sensor's later end is kept, not the open-ended copy")
        XCTAssertEqual(record.evidence, ["사무실", "떠남"])
        XCTAssertNil(model.snapshot.settings.activityCorrections[running.id])
    }

    private func later(_ record: ActualRecord) -> ActualRecord {
        var copy = record
        copy.endedAt = at(10, 45)
        return copy
    }

    func testUndoRulesForRecords() {
        let auto = ActualRecord(planID: UUID(), title: "걷기", categoryID: "movement", startedAt: at(9), endedAt: at(10), source: .motion)
        var edited = auto
        edited.planID = nil
        let change = AssistantEditDelta.Change(id: auto.id, before: auto, after: edited)
        XCTAssertNil(AssistantEditDelta.restoredActual(change, current: nil), "a record the sensors removed is not brought back from an old copy")
        let removed = AssistantEditDelta.Change(id: auto.id, before: auto, after: nil)
        XCTAssertEqual(AssistantEditDelta.restoredActual(removed, current: later(auto)), later(auto), "a re-created record is not overwritten")
        XCTAssertEqual(AssistantEditDelta.restoredActual(removed, current: nil), auto)
        var later = edited
        later.endedAt = at(10, 30)
        let merged = AssistantEditDelta.restoredActual(change, current: later)
        XCTAssertEqual(merged?.planID, auto.planID)
        XCTAssertEqual(merged?.endedAt, at(10, 30))
        XCTAssertFalse(AssistantEditDelta.blocksUndo(change, current: later))

        let manual = ActualRecord(planID: nil, title: "합침", categoryID: "work", startedAt: at(9), endedAt: at(10), source: .manual)
        let added = AssistantEditDelta.Change(id: manual.id, before: nil, after: manual)
        var userEdited = manual
        userEdited.title = "내가 고침"
        XCTAssertTrue(AssistantEditDelta.blocksUndo(added, current: userEdited), "a user's later edit of their own block wins")
        XCTAssertFalse(AssistantEditDelta.blocksUndo(added, current: manual))
    }

    // MARK: - PIN (4, 14, 대표 결정)

    private struct FixedAuthenticator: AssistantOwnerAuthenticating {
        let result: AssistantOwnerAuthResult
        func authenticate(reason: String) async -> AssistantOwnerAuthResult { result }
    }

    func testPINStatusComesFromTheServer() async {
        XCTAssertEqual(AssistantPINStore.parseStatus(Data(#"{"set":true,"locked":true,"retryAfter":600}"#.utf8)),
                       .init(isSet: true, isLocked: true, retryAfterSeconds: 600))
        XCTAssertEqual(AssistantPINStore.parseStatus(Data(#"{"set":false,"locked":false}"#.utf8)), .init(isSet: false))
        XCTAssertEqual(AssistantPINStore.parseStatus(Data(#"{"set":true,"lockedUntil":null}"#.utf8)), .init(isSet: true))
        XCTAssertNil(AssistantPINStore.parseStatus(Data("{}".utf8)))

        // POST /pin은 됐는데 응답을 잃어 기기 표시가 꺼져 있던 경우.
        let store = defaults()
        let env = environment(AssistantMemorySecrets([.master: master]), store) { _ in 200 }
        Phase3RelayStub.body = #"{"set":true,"locked":false}"#
        let status = await AssistantPINStore.status(env: env)
        XCTAssertEqual(status?.isSet, true)
        XCTAssertTrue(AssistantPINStore.isSet(store), "the local flag follows the server")
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["GET /pin"])

    }

    /// 승인 PIN은 앱 비밀번호에서 만들고, 서버에는 그 비밀번호가 아닌 값이 간다(PIN1110A01).
    func testApprovalPINIsDerivedFromTheAppPassword() {
        let salt = Data(repeating: 7, count: 32), other = Data(repeating: 8, count: 32)
        let pin = AssistantPINDerivation.pin(appPassword: "135790", salt: salt)
        XCTAssertTrue(AssistantPIN.isValid(pin), "six digits, so the server contract is unchanged")
        XCTAssertEqual(pin, AssistantPINDerivation.pin(appPassword: "135790", salt: salt), "same password and salt give the same PIN")
        XCTAssertNotEqual(pin, "135790", "the app password itself is never the server PIN")
        XCTAssertNotEqual(AssistantPINDerivation.pin(appPassword: "135791", salt: salt), pin)
        XCTAssertNotEqual(AssistantPINDerivation.pin(appPassword: "135790", salt: other), pin, "without the synced salt the PIN can't be matched to the password")
    }

    @MainActor
    func testApprovalPINSaltIsMadeOnceAndKept() {
        final class MemoryStore: BackupPasswordStore {
            var value: String?
            func read() throws -> String? { value }
            func write(_ password: String) throws { value = password }
            func delete() throws { value = nil }
        }
        let store = MemoryStore()
        let first = AssistantPINDerivation.salt(store: store)
        XCTAssertEqual(first?.count, 32)
        XCTAssertEqual(AssistantPINDerivation.salt(store: store), first, "the stored salt is reused")
        XCTAssertEqual(AssistantPINDerivation.pin(appPassword: "246801", store: store), first.map { AssistantPINDerivation.pin(appPassword: "246801", salt: $0) })
    }

    func testForgottenPINResetCutsConnectionsOnlyAfterOwnerAuthentication() async throws {
        let store = defaults()
        store.set(true, forKey: AssistantPINStore.setKey)
        AssistantKeyLabels.save("ab12cd34", label: "피클", period: .quarter, defaults: store)
        let cleared = Counter()
        let env = environment(AssistantMemorySecrets([.master: master]), store, cleared: cleared) { _ in 200 }
        Phase3RelayStub.body = #"{"reset":true,"revokedKeys":2}"#

        let refused = await AssistantPINStore.reset(env: env, authenticator: FixedAuthenticator(result: .failed), reason: "r")
        XCTAssertFalse(refused)
        XCTAssertTrue(Phase3RelayStub.requests.isEmpty, "a failed or cancelled check sends nothing")
        XCTAssertTrue(AssistantPINStore.isSet(store))
        XCTAssertEqual(AssistantKeyLabels.label("ab12cd34", defaults: store), "피클")

        let done = await AssistantPINStore.reset(env: env, authenticator: FixedAuthenticator(result: .passed), reason: "r")
        XCTAssertTrue(done)
        let request = try XCTUnwrap(Phase3RelayStub.requests.first)
        XCTAssertEqual(request.summary, "POST /pin/reset")
        XCTAssertEqual(request.token, master)
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{}")
        XCTAssertFalse(AssistantPINStore.isSet(store))
        XCTAssertNil(AssistantKeyLabels.label("ab12cd34", defaults: store), "local connection names are cleared")
        XCTAssertEqual(cleared.value, 1, "local connection keys are cleared")

        // 그 뒤 새 PIN은 지금 PIN 없이 정한다.
        Phase3RelayStub.body = #"{"ok":true}"#
        let saved = await AssistantPINStore.set(pin: "135790", current: nil, env: env)
        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(Phase3RelayStub.requests.last?.body)) as? [String: String], ["pin": "135790"])
    }

    func testPINResetWithoutADevicePasscodeAndServerFailure() async {
        let store = defaults()
        store.set(true, forKey: AssistantPINStore.setKey)
        let env = environment(AssistantMemorySecrets([.master: master]), store) { _ in 200 }
        Phase3RelayStub.body = #"{"reset":true,"revokedKeys":0}"#
        let done = await AssistantPINStore.reset(env: env, authenticator: FixedAuthenticator(result: .noPasscode), reason: "r")
        XCTAssertTrue(done, "with no device passcode the confirmation alone is enough")

        store.set(true, forKey: AssistantPINStore.setKey)
        let failing = environment(AssistantMemorySecrets([.master: master]), store) { _ in 500 }
        let failed = await AssistantPINStore.reset(env: failing, authenticator: FixedAuthenticator(result: .passed), reason: "r")
        XCTAssertFalse(failed)
        XCTAssertTrue(AssistantPINStore.isSet(store), "nothing changes locally when the server did not reset")
    }

    func testConnectionCodeWithoutAPINLeadsToCreatingOne() async {
        let store = defaults()
        store.set(true, forKey: AssistantPINStore.setKey)
        let env = environment(AssistantMemorySecrets([.master: master]), store) { _ in 409 }
        Phase3RelayStub.body = #"{"error":"pin_not_set"}"#
        let reply = await TripRelay.requestOAuthCode(env: env)
        XCTAssertEqual(reply, .pinNotSet)
        XCTAssertFalse(AssistantPINStore.isSet(store))

        let working = environment(AssistantMemorySecrets([.master: master]), store) { _ in 201 }
        Phase3RelayStub.body = #"{"code":"ABCD2345","expiresIn":600}"#
        guard case let .code(code) = await TripRelay.requestOAuthCode(env: working, now: at(12)) else { return XCTFail("no code") }
        XCTAssertEqual(code.code, "ABCD2345")
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /oauth/code"], "no PIN is asked or sent for the code")
    }

    // MARK: - 연결 키 권한 (3)

    func testTurningOffEditsReusesTheSameKeySoNoWriteKeyIsLeftBehind() async throws {
        let store = defaults()
        let saved = Counter()
        var env = environment(AssistantMemorySecrets([.master: master]), store) { _ in 201 }
        env.saveConnection = { _ in saved.value += 1; return true }
        let token = String(repeating: "K", count: 21) + String(repeating: "k", count: 22)
        let result = await TripRelay.registerScopedKey(label: "피클", scope: .read, period: .quarter, pin: "482913", existing: token, now: at(12), env: env)
        guard case let .created(key, sent) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(sent, token)
        XCTAssertEqual(key.id, AssistantKeyStore.keyID(token), "same connection id, so no second key appears")
        XCTAssertEqual(key.scope, .read)
        XCTAssertEqual(saved.value, 0)
        let request = try XCTUnwrap(Phase3RelayStub.requests.first)
        XCTAssertEqual(request.summary, "POST /keys")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let keys = try XCTUnwrap(body["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.first?["token"] as? String, token)
        XCTAssertEqual(keys.first?["scope"] as? String, "read")
        XCTAssertEqual(body["pin"] as? String, "482913")
    }

    // MARK: - 429 (11)

    func testLongOrDailyLimitsAreNotRetried() async {
        XCTAssertEqual(TripRelay.retryWait(header: "2", body: Data()), 2)
        XCTAssertNil(TripRelay.retryWait(header: "60", body: Data()), "a long wait is returned to the caller instead of blocking")
        XCTAssertNil(TripRelay.retryWait(header: "1", body: Data(#"{"error":"daily_request_limit"}"#.utf8)))

        let env = environment(AssistantMemorySecrets([.master: master]), defaults()) { _ in 429 }
        Phase3RelayStub.retryAfter = "60"
        let request = TripRelay.relayRequest("/keys", method: "GET", token: master, host: host)
        let reply = await TripRelay.send(request, session: env.session)
        XCTAssertEqual(reply?.status, 429)
        XCTAssertEqual(Phase3RelayStub.requests.count, 1)

        Phase3RelayStub.reset { _ in 429 }
        Phase3RelayStub.retryAfter = "0"
        let single = await TripRelay.$singleAttempt.withValue(true) { await TripRelay.send(request, session: env.session) }
        XCTAssertEqual(single?.status, 429)
        XCTAssertEqual(Phase3RelayStub.requests.count, 1, "background refresh never waits")
    }

    // MARK: - 말풍선 (17)

    func testBubbleGrammarMatchesTheServer() throws {
        // docs/ACTIVITY_RELAY_API.md 4.2의 예와 거절 이유들.
        for bad in [
            "[https://bank.com](https://evil.example)", "[apple.com](https://evil.example)", "[애플.com](https://evil.example)", "[www.bank](https://evil.example)",
            "봐 https://user@example.com/", "봐 https://192.0.2.1/", "봐 https://xn--abc.kr/", "봐 https://localhost/", "봐 https://example.com:99999999/",
            "봐 https://evil.example\\@trusted.example", "봐 https://example.com/%zz", "[열기](https://user:pw@evil.example)",
            "kakaotalk://open", "ETA:15", "taptionplan:x", "[a [b] c](calshow:0)", "<taptionplan:reset> hi", "남은 [괄호]", "https://example.com",
            "봐 [열기](https://example.com/a b)",
        ] {
            XCTAssertNil(AssistantBubbleText(bad), bad)
        }
        XCTAssertNil(AssistantBubbleText(String(repeating: "가", count: 60) + " https://example.com/" + String(repeating: "a", count: 240)), "300 in all")
        for good in ["Note: 메모", "12:30 출발", "시간:3시", "오늘 할 일: 3개", "봐 https://example.com:8443/a?b=1#c"] {
            XCTAssertNotNil(AssistantBubbleText(good), good)
        }

        let upper = try XCTUnwrap(AssistantBubbleText("[예약](HTTPS://Example.com) 확인"))
        XCTAssertEqual(upper.links.first?.url.absoluteString, "https://example.com", "scheme and host are lower-cased so the link opens")
        XCTAssertEqual(upper.display, "예약 확인")
        let sentence = try XCTUnwrap(AssistantBubbleText("봐 https://example.com/a. 그리고"))
        XCTAssertEqual(sentence.links.first?.url.absoluteString, "https://example.com/a", "the trailing full stop is text")
        XCTAssertEqual(sentence.display, "봐 example.com. 그리고")

        let bidi = try XCTUnwrap(AssistantBubbleText("안녕\u{202E}하세요\u{200B}\u{0007}\u{2028}"))
        XCTAssertEqual(bidi.display, "안녕하세요", "direction overrides and other invisible characters are removed")
        XCTAssertNotNil(AssistantBubbleText(String(repeating: "👍", count: 80)), "counted in code points")
        XCTAssertNil(AssistantBubbleText(String(repeating: "👍", count: 81)))

        let twice = try XCTUnwrap(AssistantBubbleText("가 https://a.com [나](https://b.com) https://a.com"))
        XCTAssertEqual(twice.links.map(\.label), ["a.com", "나", "a.com"], "links keep their order in the text")
        XCTAssertEqual(Set(twice.links.map(\.id)).count, 3)
        XCTAssertEqual(twice.display, "가 a.com 나 a.com")

        let parsed = try batch([
            command("b1", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": " 우산\u{202E} 챙겨요 "]),
            command("b2", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": "[bank.com](https://evil.example)"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.action), [.setBubble(start: at(9), end: at(10), text: "우산 챙겨요")])
        XCTAssertEqual(parsed.invalidIDs, ["b2"])
    }

    /// BBL1111A01: 10자 안팎에서 접어 아래로 늘리고, 여덟 줄에 안 들어갈 때만 넓힌다. 15자 이하는 오른쪽, 넘으면 왼쪽.
    func testBubbleWidthUsesTheWindowNotTheScreen() {
        let ten = AssistantBubbleLayout.width(String(repeating: "가", count: 10), size: 11, container: 430)
        XCTAssertEqual(AssistantBubbleLayout.width(String(repeating: "가", count: 30), size: 11, container: 430), ten, "wraps at ten characters")
        XCTAssertLessThan(AssistantBubbleLayout.width("가", size: 11, container: 300), 40)
        let long = AssistantBubbleLayout.width(String(repeating: "가", count: 200), size: 11, container: 300)
        XCTAssertEqual(long, 300 * 0.6 - 16, "200 chars don't fit eight lines, so it widens up to 60% of the window")
        XCTAssertEqual(AssistantBubbleLayout.maxLines, 8)

        XCTAssertEqual(MapHomeCatSpeechBubble.side(text: "점심 맛있게 드세요"), .right)
        XCTAssertEqual(MapHomeCatSpeechBubble.side(text: String(repeating: "가", count: 15)), .right)
        XCTAssertEqual(MapHomeCatSpeechBubble.side(text: String(repeating: "가", count: 16)), .left)
        // 짧아도 오른쪽이 사이드바에 가리면 왼쪽, 길어도 왼쪽이 화면 밖이면 오른쪽.
        let nearSidebar = CGRect(x: 250, y: 400, width: 60, height: 60)
        XCTAssertEqual(MapHomeCatSpeechBubble.placedSide(text: "안녕", bubbleWidth: 80, catFrame: nearSidebar, windowWidth: 440, trailingReserve: 139), .left)
        XCTAssertEqual(MapHomeCatSpeechBubble.placedSide(text: "안녕", bubbleWidth: 80, catFrame: nearSidebar, windowWidth: 440, trailingReserve: 8), .right)
        let atLeftEdge = CGRect(x: 10, y: 400, width: 60, height: 60)
        XCTAssertEqual(MapHomeCatSpeechBubble.placedSide(text: String(repeating: "가", count: 20), bubbleWidth: 150, catFrame: atLeftEdge, windowWidth: 440, trailingReserve: 139), .right)
        XCTAssertEqual(MapHomeCatSpeechBubble.placedSide(text: String(repeating: "가", count: 20), bubbleWidth: 150, catFrame: nil, windowWidth: 440, trailingReserve: 139), .left)
    }

    // MARK: - 주소 거르기 (16)

    func testAddressFilterGapsFromTheReview() {
        for text in ["12 rue de Rivoli", "10 Via Roma", "Via Roma 10", "5th Avenue", "350 5th Ave", "역삼1동", "종로3가", "南京东路12号", "中山路100", "8 Avenida da Liberdade"] {
            XCTAssertTrue(AssistantActivityBuilder.isAddressLike(text), text)
        }
        for text in ["스타벅스 강남역점", "Blue Bottle Coffee", "롯데월드타워", "5 Guys Burgers", "카페 동", "교보문고 광화문점"] {
            XCTAssertFalse(AssistantActivityBuilder.isAddressLike(text), text)
        }
    }

    // MARK: - 명령 처리 (8, 20)

    /// 경로마다 답을 정한 가짜 서버. `resultStatus`는 결과 보고의 응답.
    private func runnerEnvironment(_ store: UserDefaults, commands: [[String: Any]], resultStatus: @escaping () -> Int = { 201 }) -> AssistantRegistration.Environment {
        store.set(AssistantShareLevel.off.rawValue, forKey: AssistantShareLevel.defaultsKey)
        let queue = json(["commands": commands])
        let keys = json(["keys": [["id": "aaaa1111", "scope": "write", "expiresAt": NSNull(), "source": "rest"]]])
        return readyEnvironment(store) { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/command"):
                Phase3RelayStub.body = queue
                return 200
            case ("GET", "/keys"):
                Phase3RelayStub.body = keys
                return 200
            case ("POST", "/command/result"):
                Phase3RelayStub.body = "{}"
                return resultStatus()
            default:
                Phase3RelayStub.body = "{}"
                return 204
            }
        }
    }

    private func postedResults() throws -> [[String: String]] {
        try Phase3RelayStub.requests.filter { $0.summary == "POST /command/result" }.flatMap { request in
            try XCTUnwrap((try JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["results"] as? [[String: String]])
        }
    }

    func testRunnerAppliesReportsThenDeletesAndSkipsRevokedMasterAndWrongTypedCommands() async throws {
        let store = defaults()
        let model = await makeModel()
        let env = runnerEnvironment(store, commands: [
            command("m1", "addMemo", ["text": "우유 사기"]),
            command("bad", "updateTripStop", ["stopId": "x", "order": "first"]),
            command("gone", "addMemo", ["text": "끊긴 연결", "keyId": "bbbb2222"]),
            command("own", "addMemo", ["text": "주 키", "keyId": "master"]),
            ["format": "bokki-command", "version": 1, "id": "old", "action": "addMemo", "text": "예전 큐", "keyId": NSNull(), "source": "legacy"],
            ["format": "bokki-command", "version": 1, "id": "anon", "action": "addMemo", "text": "출처 없음"],
        ])
        guard case let .applied(outcome) = await AssistantCommandRunner.run(model: model, defaults: store, env: env) else { return XCTFail("not applied") }
        XCTAssertEqual(Set(model.snapshot.memos.map(\.text)), ["우유 사기", "예전 큐"], "live connections and the migrated legacy queue are applied")
        XCTAssertEqual(outcome.memos, 2)
        let results = Dictionary(uniqueKeysWithValues: try postedResults().map { ($0["id"] ?? "", $0) })
        XCTAssertEqual(results["m1"]?["status"], "applied")
        XCTAssertEqual(results["old"]?["status"], "applied")
        XCTAssertEqual(results["bad"]?["reason"], "invalid")
        XCTAssertEqual(results["gone"]?["reason"], "revoked")
        XCTAssertEqual(results["own"]?["reason"], "revoked", "the master key is not a connection")
        XCTAssertEqual(results["anon"]?["reason"], "revoked")
        let summaries = Phase3RelayStub.requests.map(\.summary)
        let firstResult = try XCTUnwrap(summaries.firstIndex(of: "POST /command/result"))
        let firstDelete = try XCTUnwrap(summaries.firstIndex(of: "DELETE /command"))
        XCTAssertLessThan(firstResult, firstDelete, "the queue is cleared only after the result is delivered")
        let journal = AssistantCommandJournal(defaults: store)
        XCTAssertTrue(journal.pending.isEmpty)
        XCTAssertEqual(AssistantActionLog.load(from: journal.logFile).map(\.commandID).sorted(), ["m1", "old"])
        try? FileManager.default.removeItem(at: journal.logFile)
    }

    func testResultsAreKeptAndResentWhenTheReportFailsAndNothingIsAppliedTwice() async throws {
        let store = defaults()
        let model = await makeModel()
        var resultStatus = 500
        let env = runnerEnvironment(store, commands: [command("m1", "addMemo", ["text": "우유 사기"])]) { resultStatus }
        _ = await AssistantCommandRunner.run(model: model, defaults: store, env: env)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertFalse(Phase3RelayStub.requests.contains { $0.summary == "DELETE /command" }, "a command is not deleted before its result is delivered")
        let journal = AssistantCommandJournal(defaults: store)
        addTeardownBlock { try? FileManager.default.removeItem(at: journal.logFile) }
        XCTAssertEqual(journal.pending, [.init(id: "m1", applied: true, reason: nil)])

        // 다음에 열면 서버 큐에 그대로 있어도 다시 반영하지 않고 결과만 다시 보낸다.
        resultStatus = 201
        let before = Phase3RelayStub.requests.count
        guard case .nothing = await AssistantCommandRunner.run(model: model, defaults: store, env: env) else { return XCTFail("applied twice") }
        XCTAssertEqual(model.snapshot.memos.count, 1)
        let later = Phase3RelayStub.requests.dropFirst(before).map(\.summary)
        XCTAssertEqual(later.first, "POST /command/result")
        XCTAssertTrue(later.contains("DELETE /command"))
        XCTAssertTrue(journal.pending.isEmpty)
    }

    func testACommandInterruptedMidApplyIsReportedNotSilentlyDropped() async throws {
        let store = defaults()
        let model = await makeModel()
        let journal = AssistantCommandJournal(defaults: store)
        addTeardownBlock { try? FileManager.default.removeItem(at: journal.logFile) }
        // 반영하다 앱이 꺼졌다: 시작 표시만 있고 결과도 「AI가 한 일」도 없다.
        journal.begin("m1")
        let env = runnerEnvironment(store, commands: [command("m1", "addMemo", ["text": "우유 사기"]), command("m2", "addMemo", ["text": "빵"])])
        _ = await AssistantCommandRunner.run(model: model, defaults: store, env: env)
        let results = Dictionary(uniqueKeysWithValues: try postedResults().map { ($0["id"] ?? "", $0) })
        XCTAssertEqual(results["m1"], ["id": "m1", "status": "rejected", "reason": "interrupted"])
        XCTAssertEqual(results["m2"]?["status"], "applied", "commands that had not started are applied normally")
        XCTAssertEqual(model.snapshot.memos.map(\.text), ["빵"])
        XCTAssertNil(store.string(forKey: AssistantCommandJournal.inProgressKey))

        // 「AI가 한 일」에 남았으면 반영된 것으로 알린다.
        let other = defaults()
        let done = AssistantCommandJournal(defaults: other)
        addTeardownBlock { try? FileManager.default.removeItem(at: done.logFile) }
        AssistantActionLog.append([AssistantLogEntry(commandID: "z", kind: .addMemo, appliedAt: at(12), before: "", after: "메모", delta: .init())], to: done.logFile)
        done.begin("z")
        done.resolveInterrupted()
        XCTAssertEqual(done.pending, [.init(id: "z", applied: true, reason: nil)])
    }
}

private extension AssistantActivityDay {
    static func empty(date: String) -> Self {
        let input = AssistantActivityInput(
            day: .now, calendar: .current, language: .korean, categories: [], steps: nil, plansScheduled: 0, plansCompleted: 0,
            actuals: [], categoryTitles: [:], memos: [], stays: [], travel: [], registeredNames: [:], now: .now
        )
        var day = AssistantActivityBuilder.make(input, level: .summary)!
        day.date = date
        return day
    }
}
