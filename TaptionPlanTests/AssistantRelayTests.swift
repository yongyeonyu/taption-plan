import Security
import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// AI 비서 연동: 하루 기록 JSON·명령 읽기·처리한 id 기억(AIR1110A01·TRP1110A07).
final class AssistantRelayTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantRelayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private let point = GeoPoint(latitude: 37.5, longitude: 127.0, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5)

    private func stay(_ key: String, _ name: String, _ from: Date, _ to: Date) -> PlaceStay {
        PlaceStay(placeKey: key, displayName: name, span: TimeSpan(start: from, end: to), confidence: .high, point: point)
    }

    private lazy var walk = ActualRecord(planID: nil, title: "걷기", categoryID: "movement", startedAt: at(8, 30), endedAt: at(9), source: .motion)
    private lazy var work = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(9), endedAt: at(18), source: .location)

    private func input() -> AssistantActivityInput {
        let home = stay("home-key", "자동 감지 장소", at(0), at(8, 30))
        let office = stay("office-key", "서울특별시 중구 세종대로 110", at(9), at(18))
        let cafe = stay("cafe-key", "블루보틀", at(18, 20), at(19, 30))
        let morning = TravelSegment(fromPlaceID: home.id, toPlaceID: office.id, mode: .subway, span: TimeSpan(start: at(8, 30), end: at(9)), distanceMeters: 8_000, confidence: .high, evidence: [])
        let evening = TravelSegment(mode: .walking, span: TimeSpan(start: at(18), end: at(18, 20)), distanceMeters: 900, confidence: .high, evidence: [])
        return AssistantActivityInput(
            day: at(0), calendar: calendar, language: .korean,
            categories: [.init(id: "work", title: "업무", minutes: 540), .init(id: "movement", title: "이동", minutes: 30)],
            steps: 6_000, plansScheduled: 2, plansCompleted: 1,
            actuals: [work, walk], categoryTitles: ["work": "업무", "movement": "이동"],
            memos: [ActionMemo(categoryID: "memo", occurredAt: at(12), mapPoint: point, kind: .idea, text: "점심 약속")],
            stays: [cafe, office, home], travel: [evening, morning],
            registeredNames: ["home-key": "우리 집"], now: at(23)
        )
    }

    private func json(_ day: AssistantActivityDay) throws -> [String: Any] {
        let data = try AssistantActivityUploadGate.encoder.encode(day)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func keys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] { return object.reduce(into: Set(object.keys)) { $0.formUnion(keys($1.value)) } }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
        return []
    }

    /// AIC1112A01: 서버가 받는 모양(`기기;빌드;공유 수준[;debug]`)만 보내고, 맞지 않으면 보내지 않는다.
    func testClientHeaderCarriesModelBuildShareLevelAndNothingElse() {
        XCTAssertEqual(TripRelay.clientHeader(model: "iPhone12,3", build: "323", level: .summary, debug: false, locked: false), "iPhone12,3;323;summary")
        XCTAssertEqual(TripRelay.clientHeader(model: "iPhone19,7", build: "324", level: .visits, debug: true, locked: false), "iPhone19,7;324;visits;debug")
        XCTAssertEqual(TripRelay.clientHeader(model: "민수의 iPhone;x", build: "1", level: .off, debug: false, locked: false), "iPhonex;1;off")
        XCTAssertNil(TripRelay.clientHeader(model: "12,3", build: "323", level: .summary, debug: false, locked: false))
        XCTAssertNil(TripRelay.clientHeader(model: "iPhone12,3", build: "3.2", level: .summary, debug: false, locked: false))
        XCTAssertNil(TripRelay.clientHeader(model: "iPhone12,3", build: nil, level: .summary, debug: false, locked: false))
        // AIL1112A01: 사생활 잠금 중이면 올리기를 쉰다는 표시를 붙인다.
        XCTAssertEqual(TripRelay.clientHeader(model: "iPhone12,3", build: "327", level: .summary, debug: false, locked: true), "iPhone12,3;327;summary;locked")
        XCTAssertEqual(TripRelay.clientHeader(model: "iPhone12,3", build: "327", level: .visits, debug: true, locked: true), "iPhone12,3;327;visits;debug;locked")
        let request = TripRelay.relayRequest("/command", method: "GET", token: "K", host: "example.com", client: .live)
        let live = AssistantClientState.live
        XCTAssertEqual(request?.value(forHTTPHeaderField: TripRelay.clientHeaderName), TripRelay.clientHeader(level: live.level, debug: live.debug, locked: live.locked))
        XCTAssertFalse(TripRelay.hardwareModel.isEmpty)
    }

    /// AIC1112A01: 백그라운드 깨어남이 잦아도 5분에 한 번만 돈다.
    @MainActor
    func testBackgroundTurnIsTakenOncePerInterval() {
        let defaults = defaults()
        XCTAssertTrue(AssistantCommandRunner.takeBackgroundTurn(now: at(9), defaults: defaults))
        XCTAssertFalse(AssistantCommandRunner.takeBackgroundTurn(now: at(9, 4), defaults: defaults))
        XCTAssertTrue(AssistantCommandRunner.takeBackgroundTurn(now: at(9, 5), defaults: defaults))
        XCTAssertTrue(AssistantCommandRunner.takeBackgroundTurn(now: at(8), defaults: defaults), "시계가 뒤로 가면 막지 않는다")
    }

    func testDayJSONHasNoCoordinateOrAddressKeysAtEitherLevel() throws {
        for level in [AssistantShareLevel.summary, .visits] {
            let day = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: level))
            let found = keys(try json(day))
            XCTAssertTrue(found.isDisjoint(with: ["lat", "lng", "latitude", "longitude", "address", "point", "route"]), "\(level): \(found)")
        }
        XCTAssertNil(AssistantActivityBuilder.make(input(), level: .off))
    }

    /// PLN1111A01 제안 4(T0 읽기): 오늘에만 이 달 예산, 10분 넘는 미확인 시간은 id와 함께. 없으면 칸째 빠져 예전 날의 글자가 그대로다.
    func testBudgetOnlyTodayAndUnconfirmedSpansCarryIDs() throws {
        let plain = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: .summary))
        XCTAssertNil(plain.budget)
        XCTAssertTrue(keys(try json(plain)).isDisjoint(with: ["budget"]))

        var today = input()
        today.budget = .init(month: "2026-11", amountKRW: 500_000, spentKRW: 123_400)
        let day = try XCTUnwrap(AssistantActivityBuilder.make(today, level: .summary))
        XCTAssertEqual(day.budget, .init(month: "2026-11", amountKRW: 500_000, spentKRW: 123_400))
        // 틈은 기록이 없는 시간이다(ACT1111A01): 00:00~08:30, 18:00~23:00(지금). 걷기 08:30~09:00과 업무 09~18시는 틈이 아니다.
        XCTAssertEqual(day.unconfirmed?.map(\.minutes), [510, 300])
        XCTAssertEqual(day.unconfirmed?.first?.start, "2026-11-10T00:00+09:00")
        XCTAssertNotNil(AssistantActivityBuilder.make(today, level: .visits)?.moves?.first?.id, "이동에는 고칠 때 쓰는 id가 붙는다")

        var yesterday = today
        yesterday.now = at(23).addingTimeInterval(86_400)
        XCTAssertNil(AssistantActivityBuilder.make(yesterday, level: .summary)?.budget, "지난 날에는 예산을 싣지 않는다")
    }

    func testSummaryLevelHasRecordsAndMemosButNoPlaces() throws {
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: .summary))
        XCTAssertNil(day.visits)
        // 요약 단계의 이동은 번호·수단·시각만이고 장소 이름은 없다(BCF1114A01).
        let moves = try XCTUnwrap(day.moves)
        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { $0.from == nil && $0.to == nil && $0.id != nil })
        XCTAssertEqual(day.date, "2026-11-10")
        XCTAssertEqual(day.timeZone, "Asia/Seoul")
        XCTAssertEqual(day.summary.recordedMinutes, 570)
        XCTAssertEqual(day.summary.steps, 6_000)
        XCTAssertEqual(day.records.map(\.title), ["걷기", "업무"], "time order")
        XCTAssertEqual(day.records.first?.start, "2026-11-10T08:30+09:00")
        XCTAssertEqual(day.records.first?.source, "auto")
        XCTAssertEqual(day.records.last?.category.id, "work")
        XCTAssertEqual(day.memos.map(\.text), ["점심 약속"])
        XCTAssertEqual(day.memos.first?.time, "12:00")
        let text = String(decoding: try AssistantActivityUploadGate.encoder.encode(day), as: UTF8.self)
        for name in ["우리 집", "블루보틀", "세종대로"] { XCTAssertFalse(text.contains(name), name) }
    }

    func testDetailedLevelBuildsVisitsAndMovesInTimeOrderWithSafeNames() throws {
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: .visits))
        XCTAssertEqual(day.visits?.map(\.place), ["우리 집", "머문 곳", "블루보틀"], "registered name, address hidden, plain name kept")
        XCTAssertEqual(day.visits?.first?.minutes, 510)
        let moves = try XCTUnwrap(day.moves)
        XCTAssertEqual(moves.map(\.mode), ["subway", "walk"])
        XCTAssertEqual(moves[0].from, "우리 집")
        XCTAssertEqual(moves[0].to, "머문 곳")
        XCTAssertEqual(moves[1].from, "머문 곳", "nearest stay before")
        XCTAssertEqual(moves[1].to, "블루보틀", "nearest stay after")
        XCTAssertEqual(moves[1].start, "2026-11-10T18:00+09:00")
    }

    func testUnknownEndpointsAreNullNotMissing() throws {
        var source = input()
        source.stays = []
        let day = try XCTUnwrap(AssistantActivityBuilder.make(source, level: .visits))
        let moves = try XCTUnwrap(try json(day)["moves"] as? [[String: Any]])
        XCTAssertTrue(moves[0]["from"] is NSNull)
        XCTAssertTrue(moves[0]["to"] is NSNull)
    }

    func testAddressLikeNames() {
        for text in ["서울특별시 중구 세종대로 110", "테헤란로 152", "역삼동 737-32", "37.5665, 126.9780", "1 Infinite Loop Dr"] {
            XCTAssertTrue(AssistantActivityBuilder.isAddressLike(text), text)
        }
        for text in ["블루보틀", "스타벅스", "Blue Bottle Coffee"] {
            XCTAssertFalse(AssistantActivityBuilder.isAddressLike(text), text)
        }
    }

    func testIdenticalDayIsSkippedEvenWhenOnlyUpdatedAtChanges() throws {
        let store = defaults()
        var day = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: .summary))
        day.updatedAt = "2026-11-10T12:00+09:00"
        XCTAssertEqual(AssistantActivityUploadGate.changed([day], defaults: store).count, 1)
        AssistantActivityUploadGate.markSent([day], defaults: store)
        day.updatedAt = "2026-11-10T12:05+09:00"
        XCTAssertTrue(AssistantActivityUploadGate.changed([day], defaults: store).isEmpty)
        day.memos.append(.init(id: "m2", time: nil, text: "새 메모"))
        XCTAssertEqual(AssistantActivityUploadGate.changed([day], defaults: store).count, 1)
        AssistantActivityUploadGate.reset(defaults: store)
        day.memos.removeLast()
        XCTAssertEqual(AssistantActivityUploadGate.changed([day], defaults: store).count, 1)
    }

    func testUploadBodyCarriesFormatAndRetention() throws {
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input(), level: .summary))
        let bodies = AssistantActivityUploadGate.bodies([day, day], retentionDays: 30)
        XCTAssertEqual(bodies.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0].body) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "bokki-activity")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["retentionDays"] as? Int, 30)
        XCTAssertEqual((object["days"] as? [Any])?.count, 2)
        let single = try XCTUnwrap(AssistantActivityUploadGate.bodies([day], retentionDays: 7).first).body.count
        XCTAssertEqual(AssistantActivityUploadGate.bodies([day, day], retentionDays: 7, limit: single + 20).map(\.days.count), [1, 1])
        XCTAssertTrue(AssistantActivityUploadGate.bodies([day], retentionDays: 7, limit: single - 1).isEmpty, "a day too big alone is dropped")
    }

    // MARK: - 명령

    private func commands(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(15), calendar: calendar))
    }

    private func command(_ id: String, _ action: String, _ extra: [String: Any]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": action].merging(extra) { $1 }
    }

    func testCommandParsingAndValidation() throws {
        let batch = try commands([
            command("m1", "addMemo", ["text": "우유 사기", "time": "18:30"]),
            command("m2", "addMemo", ["text": "내일 메모", "date": "2026-11-11"]),
            command("m3", "addMemo", ["text": ""]),
            command("s1", "addSchedule", ["title": "치과", "start": "2026-11-12T15:00+09:00", "note": "검진"]),
            command("s2", "addSchedule", ["title": "치과", "start": "2026-11-12T15:00+09:00", "end": "2026-11-12T14:00+09:00"]),
            command("u1", "updateActivity", ["date": "2026-11-10", "startTime": "14:00", "title": "점심"]),
            command("u2", "updateActivity", ["date": "2026-11-10", "startTime": "14:00"]),
            command("x1", "deleteAll", [:]),
            ["format": "bokki-command", "version": 2, "id": "v2", "action": "addMemo", "text": "a"],
        ])
        XCTAssertEqual(batch.commands.map(\.id), ["m1", "m2", "s1", "u1"])
        XCTAssertEqual(batch.invalidIDs, ["m3", "s2", "u2", "x1", "v2"])
        XCTAssertEqual(batch.commands[0].action, .addMemo(text: "우유 사기", at: at(18, 30)))
        let tomorrowNoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        XCTAssertEqual(batch.commands[1].action, .addMemo(text: "내일 메모", at: tomorrowNoon))
        guard case let .addSchedule(_, start, end, note, _) = batch.commands[2].action else { return XCTFail() }
        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15)))
        XCTAssertNil(end)
        XCTAssertEqual(note, "검진")
        XCTAssertEqual(batch.commands[3].action, .updateActivity(day: at(0), recordID: nil, startTime: at(14), title: "점심", categoryID: nil))
    }

    func testUpdateActivityTargetsCoveringRecordAndOnlyAddsACorrection() throws {
        let lunch = ActualRecord(planID: nil, title: "식사", categoryID: "eating", startedAt: at(12), endedAt: at(13), source: .motion)
        let actuals = [work, walk, lunch]
        XCTAssertEqual(AssistantActivityTarget.record(id: nil, at: at(12, 30), day: at(0), in: actuals, now: at(23), calendar: calendar)?.id, lunch.id, "the later, more specific record wins")
        XCTAssertEqual(AssistantActivityTarget.record(id: nil, at: at(14), day: at(0), in: actuals, now: at(23), calendar: calendar)?.id, work.id)
        XCTAssertNil(AssistantActivityTarget.record(id: nil, at: at(20), day: at(0), in: actuals, now: at(23), calendar: calendar))
        XCTAssertEqual(AssistantActivityTarget.record(id: walk.id.uuidString, at: nil, day: at(0), in: actuals)?.id, walk.id)
        XCTAssertNil(AssistantActivityTarget.record(id: UUID().uuidString, at: nil, day: at(0), in: actuals))

        let option = AssistantActivityTarget.option(for: work, title: "회의", categoryID: nil)
        XCTAssertEqual(option.categoryID, "work")
        let correction = ActivityCorrectionEngine.replacingActivity(in: nil, with: option)
        let original = work
        let shown = ActivityCorrectionEngine.applying([work.id: correction], to: [original])
        XCTAssertEqual(shown.first?.title, "회의")
        XCTAssertEqual(shown.first?.manuallyCorrected, true)
        XCTAssertEqual(shown.first?.source, .location, "provenance is kept")
        XCTAssertEqual(original.title, "업무")
        XCTAssertFalse(original.manuallyCorrected)
        XCTAssertEqual(AssistantActivityTarget.option(for: work, title: nil, categoryID: "study").title, "업무")
    }

    func testHandledCommandIDsAreRememberedUpToTheLimit() throws {
        let store = defaults()
        let batch = try commands([command("a", "addMemo", ["text": "1"]), command("b", "addMemo", ["text": "2"])])
        AssistantCommandLedger.remember(["a"], defaults: store)
        XCTAssertEqual(AssistantCommandLedger.unseen(batch, defaults: store).commands.map(\.id), ["b"])
        AssistantCommandLedger.remember((0..<250).map { "x\($0)" }, defaults: store)
        XCTAssertEqual(AssistantCommandLedger.handled(store).count, AssistantCommandLedger.limit)
        XCTAssertEqual(AssistantCommandLedger.unseen(batch, defaults: store).commands.map(\.id), ["a", "b"], "oldest ids fall off")
        AssistantCommandLedger.forget(["x249"], defaults: store)
        XCTAssertFalse(AssistantCommandLedger.handled(store).contains("x249"))
    }

    func testCommandNoticeSummarizesCounts() {
        var outcome = AssistantCommandOutcome()
        outcome.memos = 1
        outcome.edits = 1
        outcome.results = [.init(id: "a", applied: true), .init(id: "b", applied: true), .init(id: "c", applied: false, reason: "no_record")]
        XCTAssertEqual(outcome.notice(.korean), "AI 비서 요청을 반영했어요: 메모 1개 · 기록 수정 1개 · 못 한 것 1개")
        XCTAssertNil(AssistantCommandOutcome().notice(.korean))
    }

    func testSetupTextNamesEveryRouteAndTheKey() {
        let key = String(repeating: "A", count: 43)
        let text = TripRelay.assistantSetupText(host: "relay.example.com", key: key, timeZone: TimeZone(identifier: "Asia/Seoul")!)
        for part in ["https://relay.example.com", "Bearer \(key)", "GET /activity", "POST /plan", "POST /command", "addMemo", "addSchedule", "updateActivity", "GET /command/result", "+09:00", "GET /polish", "cannot wake you", "every 10 minutes"] {
            XCTAssertTrue(text.contains(part), part)
        }
    }

    /// SYN1111A03: AI와 대화 중이면 빠르게, 「대화 끝」이나 5분 조용하면 10분, 직접 새로고침하면 2분 빠르게.
    @MainActor
    func testCommandPollingFollowsConversation() {
        let now = at(12)
        typealias P = AssistantCommandPolling
        let talking = P.Signal(seenAgo: 30, ended: false, receivedAt: now)
        XCTAssertTrue(P.isConversation(signal: talking, manualAt: nil, now: now))
        XCTAssertFalse(P.isConversation(signal: talking, manualAt: nil, now: now.addingTimeInterval(271)), "5 minutes without AI")
        XCTAssertFalse(P.isConversation(signal: P.Signal(seenAgo: 5, ended: true, receivedAt: now), manualAt: nil, now: now), "AI ended it")
        XCTAssertFalse(P.isConversation(signal: P.Signal(seenAgo: nil, ended: false, receivedAt: now), manualAt: nil, now: now), "AI never came")
        XCTAssertTrue(P.isConversation(signal: P.Signal(seenAgo: 5, ended: true, receivedAt: now), manualAt: now.addingTimeInterval(-60), now: now), "manual refresh restarts")
        XCTAssertFalse(P.isConversation(signal: nil, manualAt: now.addingTimeInterval(-121), now: now))
        XCTAssertEqual(P.interval(conversation: true, lowPower: false, thermal: .nominal), 10)
        XCTAssertEqual(P.interval(conversation: true, lowPower: true, thermal: .nominal), 20)
        XCTAssertEqual(P.interval(conversation: true, lowPower: false, thermal: .serious), 60)
        XCTAssertEqual(P.interval(conversation: false, lowPower: false, thermal: .nominal), 300)
        let response = HTTPURLResponse(url: URL(string: "https://example.com/command")!, statusCode: 204, httpVersion: nil,
                                       headerFields: ["x-ai-seen-ago": "42", "x-ai-ended": "1"])!
        XCTAssertEqual(P.signal(from: response, now: now), P.Signal(seenAgo: 42, ended: true, receivedAt: now))
        let never = HTTPURLResponse(url: URL(string: "https://example.com/command")!, statusCode: 204, httpVersion: nil, headerFields: ["x-ai-seen-ago": "-1"])!
        XCTAssertNil(P.signal(from: never, now: now)?.seenAgo)
        XCTAssertEqual(TripRelay.commandFetchTimeout, 5)
        XCTAssertEqual(TripRelay.relayRequest("/command", method: "GET", token: "K", host: "example.com", client: .live, timeout: TripRelay.commandFetchTimeout)?.timeoutInterval, 5)
    }

    // MARK: - 기존 설치와의 약속 (PKG1114A19) — 코드를 옮겨도 이 글자들은 그대로여야 연결이 유지된다.

    /// 기기 설정 키. 한 글자라도 바뀌면 등록·PIN·연결 이름·맡긴 일·질문이 사라진 것처럼 보인다.
    @MainActor
    func testStoredDefaultsKeysAreUnchanged() {
        XCTAssertEqual(
            [AssistantRegistration.registeredKey, AssistantRegistration.searchRegisteredKey, AssistantRegistration.rotationKey,
             AssistantRegistration.rotationTag, AssistantRegistration.reconnectKey],
            ["assistantRegisteredMasterID", "assistantRegisteredSearchID", "assistantMasterRotation", "SEC1110A02", "assistantNeedsReconnect"]
        )
        XCTAssertEqual(AssistantPINStore.setKey, "assistantPINSet")
        XCTAssertEqual(
            [AssistantKeyLabels.labelsKey, AssistantKeyLabels.periodsKey, AssistantKeyLabels.serverCountKey, AssistantKeyLabels.clientsKey,
             AssistantKeyProviders.defaultsKey],
            ["assistantKeyLabels", "assistantKeyPeriods", "assistantServerKeyCount", "assistantKeyClients", "assistantKeyProviders"]
        )
        XCTAssertEqual([AssistantShareLevel.defaultsKey, AssistantRetention.defaultsKey], ["assistantShareLevel", "assistantRetentionDays"])
        XCTAssertEqual(AssistantShareLevel.allCases.map(\.rawValue), ["off", "summary", "visits"])
        XCTAssertEqual(AssistantRetention.allCases.map(\.rawValue), [1, 7, 30])
        XCTAssertEqual(
            [AssistantActivityUploadGate.defaultsKey, AssistantActivitySync.sharedKey, AssistantActivitySync.pendingClearKey],
            ["assistantActivityHashes", "assistantActivityShared", "assistantActivityPendingClear"]
        )
        XCTAssertEqual(
            [AITaskQueue.uploadsKey, AITaskQueue.cacheKey, AITaskQueue.ackedKey, AITaskQueue.finishedSeenKey],
            ["aiTaskUploads", "aiTaskCache", "aiTaskAcked", "aiTaskFinishedSeen"]
        )
        XCTAssertEqual([AssistantQuestionStore.key, AssistantQuestionStore.dirtyKey], ["assistantQuestions", "assistantQuestionsDirty"])
        XCTAssertEqual(AssistantQuestionNotice.identifier("q1"), "assistant-question-q1")
        XCTAssertEqual(TripRelay.rotationDeletionPaths, ["/keys", "/activity", "/command", "/plan"])
        XCTAssertEqual(AssistantKeyStore.keyID("abc"), "ba7816bf")
        XCTAssertEqual(AssistantCommandLedger.defaultsKey, "assistantCommandHandledIDs")
        XCTAssertEqual(
            [AssistantCommandJournal.inProgressKey, AssistantCommandJournal.outboxKey, AssistantCommandRunner.backgroundRunKey],
            ["assistantCommandInProgressID", "assistantCommandPendingResults", "assistantBackgroundRunAt"]
        )
    }

    private func keychainText(service: String, account: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 키체인의 서비스·계정 글자. 주 키·검색 키는 읽기만 하고, 비어 있는 자리와 새 연결 키로만 써 본다.
    @MainActor
    func testKeychainServiceAndAccountsAreUnchanged() throws {
        let service = "com.taption.plan.triprelay"
        let secrets = AssistantKeychainSecrets.shared
        XCTAssertEqual(secrets.read(.master), keychainText(service: service, account: "relay-key"))
        XCTAssertEqual(secrets.read(.search), keychainText(service: service, account: "search-key"))
        XCTAssertEqual(secrets.read(.pendingMaster), keychainText(service: service, account: "relay-key-pending"))
        if let master = keychainText(service: service, account: "relay-key"), TripRelay.isValidKey(master) { XCTAssertEqual(TripRelay.key, master) }
        let token = try XCTUnwrap(TripRelay.randomToken())
        if secrets.read(.pendingMaster) == nil {
            guard secrets.write(token, to: .pendingMaster) else { throw XCTSkip("이 시험 환경에서는 키체인에 쓸 수 없다") }
            XCTAssertEqual(keychainText(service: service, account: "relay-key-pending"), token)
            secrets.write(nil, to: .pendingMaster)
            XCTAssertNil(keychainText(service: service, account: "relay-key-pending"))
        }
        guard AssistantKeyStore.save(token) else { throw XCTSkip("이 시험 환경에서는 키체인에 쓸 수 없다") }
        let id = AssistantKeyStore.keyID(token)
        XCTAssertEqual(keychainText(service: "com.taption.plan.triprelay.scoped", account: id), token)
        XCTAssertEqual(AssistantKeyStore.token(for: id), token)
        AssistantKeyStore.remove(id)
        XCTAssertNil(keychainText(service: "com.taption.plan.triprelay.scoped", account: id))
    }

    /// 서버가 받는 요청 모양: 주소·방식·헤더 세 개·몸통.
    func testRelayRequestShapeIsUnchanged() throws {
        let client = AssistantClientState(level: .visits, debug: false, locked: true)
        let body = Data(#"{"a":1}"#.utf8)
        let request = try XCTUnwrap(TripRelay.relayRequest(
            "/rules", method: "POST", query: [URLQueryItem(name: "since", value: "3")], body: body, token: "KEY", host: "relay.example.com", client: client
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/rules?since=3")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(TripRelay.clientHeaderName, "x-bokki-client")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Authorization": "Bearer KEY", "Content-Type": "application/json", "x-bokki-client": "\(TripRelay.hardwareModel);\(build);visits;locked",
        ])
        let plain = try XCTUnwrap(TripRelay.relayRequest("/keys", method: "GET", token: "KEY", host: "relay.example.com", client: client))
        XCTAssertEqual(plain.url?.absoluteString, "https://relay.example.com/keys")
        XCTAssertEqual(Set(plain.allHTTPHeaderFields?.keys.map { $0 } ?? []), ["Authorization", "x-bokki-client"])
        XCTAssertNil(plain.httpBody)
        // 키 등록 몸통과 일 올리기 본문의 칸 이름.
        let keys = try XCTUnwrap(TripRelay.keysBody(token: "T", scope: .read, expiresAt: nil, pin: "123456"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: keys) as? [String: Any])
        XCTAssertEqual(object["pin"] as? String, "123456")
        let key = try XCTUnwrap((object["keys"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(key.keys), ["token", "scope", "expiresAt"])
        XCTAssertEqual(key["scope"] as? String, "read")
        XCTAssertTrue(key["expiresAt"] is NSNull)
        XCTAssertEqual(TripRelay.isoText(Date(timeIntervalSince1970: 1_800_000_000)), "2027-01-15T08:00:00Z")
    }

    /// PSH1114A06: 푸시 종류 읽기, 기기 토큰 글자, 같은 토큰을 다시 올리지 않기.
    func testPushHelpers() {
        XCTAssertEqual(AssistantPush.kind(from: ["aps": ["content-available": 1], "k": "cmd"]), .cmd)
        XCTAssertEqual(["q", "task", "rules"].map { AssistantPush.kind(from: ["k": $0]) }, [.q, .task, .rules])
        XCTAssertNil(AssistantPush.kind(from: ["k": "other"]))
        XCTAssertNil(AssistantPush.kind(from: ["k": 1]))
        XCTAssertNil(AssistantPush.kind(from: ["aps": ["alert": "x"]]))
        XCTAssertEqual(AssistantPush.hex(Data([0x00, 0x0f, 0xa0, 0xff])), "000fa0ff")
        XCTAssertEqual(AssistantPush.hex(Data(repeating: 0xab, count: 32)).count, 64)

        let store = defaults(), now = at(12), token = String(repeating: "ab", count: 32)
        XCTAssertTrue(AssistantPush.needsUpload(token: token, environment: "production", defaults: store, now: now))
        store.set("production:\(token)", forKey: AssistantPush.uploadedKey)
        store.set(now.timeIntervalSince1970, forKey: AssistantPush.uploadedAtKey)
        XCTAssertFalse(AssistantPush.needsUpload(token: token, environment: "production", defaults: store, now: now.addingTimeInterval(3_600)))
        XCTAssertTrue(AssistantPush.needsUpload(token: token, environment: "sandbox", defaults: store, now: now), "other environment")
        XCTAssertTrue(AssistantPush.needsUpload(token: String(repeating: "cd", count: 32), environment: "production", defaults: store, now: now), "new token")
        XCTAssertTrue(AssistantPush.needsUpload(token: token, environment: "production", defaults: store, now: now.addingTimeInterval(AssistantPush.reuploadAfter)), "weekly")
        XCTAssertTrue(AssistantPush.needsUpload(token: token, environment: "production", defaults: store, now: now.addingTimeInterval(-60)), "clock went back")
    }

    /// 연결이 있을 때만 주인 키로 올리고, 같은 토큰은 한 번만. 연결이 없어지면 서버의 토큰을 지운다.
    @MainActor
    func testPushTokenUploadAndRemoval() async throws {
        let store = defaults(), master = String(repeating: "M", count: 43), token = String(repeating: "ab", count: 32)
        Phase3RelayStub.reset(status: { $0.httpMethod == "DELETE" ? 204 : 200 })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase3RelayStub.self]
        let env = AssistantRegistration.Environment(
            secrets: AssistantMemorySecrets([.master: master]), defaults: store, session: URLSession(configuration: configuration),
            host: "relay.example.com", clearConnections: {}, client: { .live }
        )
        await AssistantPush.upload(token: token, environment: "sandbox", env: env)
        XCTAssertTrue(Phase3RelayStub.requests.isEmpty, "no AI connection, no upload")

        store.set(1, forKey: AssistantKeyLabels.serverCountKey)
        await AssistantPush.upload(token: token, environment: "sandbox", env: env)
        await AssistantPush.upload(token: token, environment: "sandbox", env: env)
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /push/token"])
        let sent = try XCTUnwrap(Phase3RelayStub.requests.first)
        XCTAssertEqual(sent.token, master)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: String])
        XCTAssertEqual(body["token"], token)
        XCTAssertEqual(body["env"], "sandbox")
        XCTAssertFalse(AssistantPush.needsUpload(token: token, environment: "sandbox", defaults: store))

        await AssistantPush.syncRegistration(env: env)
        XCTAssertEqual(Phase3RelayStub.requests.count, 1, "still connected: nothing to remove")
        store.set(0, forKey: AssistantKeyLabels.serverCountKey)
        await AssistantPush.syncRegistration(env: env)
        await AssistantPush.syncRegistration(env: env)
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /push/token", "DELETE /push/token"])
        XCTAssertTrue(AssistantPush.needsUpload(token: token, environment: "sandbox", defaults: store))
    }
}
