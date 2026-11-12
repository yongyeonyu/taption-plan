import UIKit
import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 3단계: 주 키 등록·바꾸기, PIN, 검색 키, 클립보드, 주소 거르기, 연결 키 거르기, 새 명령(SEC1110A02·AIR1110A03·AIR1110A04).
@MainActor
final class AssistantPhase3Tests: XCTestCase {
    private let host = "relay.example.com"
    private let oldMaster = String(repeating: "O", count: 21) + String(repeating: "o", count: 22)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantPhase3Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func environment(_ secrets: AssistantSecretStore, _ store: UserDefaults, status: @escaping (URLRequest) -> Int = { _ in 201 }) -> AssistantRegistration.Environment {
        Phase3RelayStub.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase3RelayStub.self]
        return AssistantRegistration.Environment(
            secrets: secrets, defaults: store, session: URLSession(configuration: configuration), host: host, clearConnections: {}
        )
    }

    // MARK: - PIN

    func testPINIsSentOverTLSOnlyAndNeverPersisted() async throws {
        let pin = "482913"
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: oldMaster])
        let env = environment(secrets, store)
        XCTAssertFalse(AssistantPINStore.isSet(store))
        let saved = await AssistantPINStore.set(pin: pin, current: nil, env: env)
        XCTAssertEqual(saved, .saved)
        let request = try XCTUnwrap(Phase3RelayStub.requests.first)
        XCTAssertEqual(request.summary, "POST /pin")
        XCTAssertEqual(request.token, oldMaster)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.body) as? [String: String], ["pin": pin])
        XCTAssertTrue(AssistantPINStore.isSet(store))

        let changed = await AssistantPINStore.set(pin: "111111", current: pin, env: env)
        XCTAssertEqual(changed, .saved)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Phase3RelayStub.requests[1].body) as? [String: String], ["pin": "111111", "currentPin": pin])

        // 키체인·설정·파일 어디에도 PIN 글자를 쓰지 않는다.
        for value in secrets.values.values { XCTAssertFalse(value.contains(pin) || value.contains("111111")) }
        let persisted = store.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(persisted.contains(pin) || persisted.contains("111111"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let files = FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for url in files {
            if let text = try? String(contentsOf: url, encoding: .utf8) { XCTAssertFalse(text.contains("\"\(pin)\""), url.path) }
        }

        let wrongEnv = environment(secrets, store) { _ in 403 }
        Phase3RelayStub.body = #"{"error":"wrong_pin","message":"PIN","remaining":3}"#
        let wrong = await AssistantPINStore.set(pin: "222222", current: "000000", env: wrongEnv)
        guard case let .refused(refusal) = wrong else { return XCTFail("\(wrong)") }
        XCTAssertEqual(refusal.kind, .wrongPIN)
        XCTAssertEqual(refusal.remaining, 3)
        let invalid = await AssistantPINStore.set(pin: "12345", current: nil, env: env)
        XCTAssertEqual(invalid, .invalid, "five digits are rejected")

        // 연결 키 만들기는 몸통에만 PIN을 싣는다.
        let keys = try XCTUnwrap(TripRelay.keysBody(token: String(repeating: "S", count: 43), scope: .write, expiresAt: nil, pin: pin))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: keys) as? [String: Any])?["pin"] as? String, pin)
    }

    func testTooManyRequestsWaitsAndRetriesThenResumes() async throws {
        XCTAssertEqual(TripRelay.retryDelay(header: "2", body: Data()), 2)
        XCTAssertEqual(TripRelay.retryDelay(header: nil, body: Data(#"{"retryAfter":5}"#.utf8)), 5)
        XCTAssertEqual(TripRelay.retryDelay(header: nil, body: Data()), 15)
        XCTAssertEqual(TripRelay.retryDelay(header: "600", body: Data()), 60)
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: oldMaster])
        // 새 주 키 등록이 처음 한 번 429를 받아도 기다렸다 이어 간다.
        var limited = 0
        let old = oldMaster
        let env = environment(secrets, store) { request in
            guard request.url?.path == "/register", request.value(forHTTPHeaderField: "Authorization") != "Bearer \(old)", limited == 0 else { return 201 }
            limited += 1
            return 429
        }
        Phase3RelayStub.retryAfter = "0"
        let ready = await AssistantRegistration.prepare(env)
        XCTAssertTrue(ready)
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), [
            "POST /register", "POST /register", "POST /register", "DELETE /keys", "DELETE /activity", "DELETE /command", "DELETE /plan",
        ])
        // 두 번 다시 해도 429면 멈추고, 만들어 둔 새 키로 다음에 이어 간다.
        let busy = AssistantMemorySecrets([.master: oldMaster])
        let stuck = environment(busy, defaults()) { _ in 429 }
        Phase3RelayStub.retryAfter = "0"
        let stopped = await AssistantRegistration.prepare(stuck)
        XCTAssertFalse(stopped)
        XCTAssertEqual(Phase3RelayStub.requests.count, 3, "the new master is tried three times; nothing else is sent")
        XCTAssertNotNil(busy.read(.pendingMaster))
    }

    func testServerLockoutAndWrongPINMessages() {
        let locked = AssistantServerRefusal.parse(status: 423, data: Data(#"{"error":"pin_locked","message":"15분 뒤 다시","retryAfter":600}"#.utf8))
        XCTAssertEqual(locked?.kind, .locked)
        XCTAssertEqual(locked?.retryAfterSeconds, 600)
        XCTAssertTrue(locked?.text(.korean).contains("15분 뒤 다시") == true, "the server's message is shown")
        XCTAssertTrue(locked?.text(.korean).contains("10분") == true)
        let wrong = AssistantServerRefusal.parse(status: 403, data: Data(#"{"error":"wrong_pin","remaining":2}"#.utf8))
        XCTAssertEqual(wrong?.kind, .wrongPIN)
        XCTAssertEqual(wrong?.remaining, 2)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 429, data: Data(#"{"error":"pin_locked"}"#.utf8), retryAfterHeader: "120")?.retryAfterSeconds, 120)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 422, data: Data(#"{"error":"invalid"}"#.utf8))?.kind, .invalid)
        // CUE1110A01: 연결 키 만들기의 다른 거절도 이유별 문구로 보인다.
        XCTAssertEqual(AssistantServerRefusal.parse(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))?.kind, .unauthorized)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 422, data: Data(#"{"error":"too_many_keys"}"#.utf8))?.kind, .tooManyKeys)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 409, data: Data(#"{"error":"key_conflict"}"#.utf8))?.kind, .conflict)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 409, data: Data(#"{"error":"pin_not_set"}"#.utf8))?.kind, .pinNotSet)
        let busy = AssistantServerRefusal.parse(status: 429, data: Data(#"{"error":"rate_limited","retryAfter":30}"#.utf8))
        XCTAssertEqual(busy?.kind, .rateLimited)
        XCTAssertEqual(busy?.text(.korean), "요청이 많아요. 30초 뒤 다시 해 주세요.")
        XCTAssertEqual(AssistantServerRefusal.parse(status: 423, data: Data(#"{"error":"pin_locked","retryAfter":600}"#.utf8))?.kind, .locked)
    }

    // MARK: - 등록·바꾸기

    func testFirstLaunchGeneratesAndRegistersTheMaster() async throws {
        let store = defaults()
        let secrets = AssistantMemorySecrets()
        let env = environment(secrets, store)
        let ready = await AssistantRegistration.prepare(env)
        XCTAssertTrue(ready)
        let master = try XCTUnwrap(secrets.read(.master))
        XCTAssertTrue(TripRelay.isValidKey(master))
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /register"])
        XCTAssertEqual(Phase3RelayStub.requests.first?.token, master)
        XCTAssertTrue(AssistantRegistration.isReady(env))
        XCTAssertNil(secrets.read(.pendingMaster))
        XCTAssertFalse(store.bool(forKey: AssistantRegistration.reconnectKey))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(Phase3RelayStub.requests.first?.body)) as? [String: String], [:],
                       "no PIN material is sent to /register")

        let again = await AssistantRegistration.prepare(env)
        XCTAssertTrue(again)
        XCTAssertEqual(Phase3RelayStub.requests.count, 1, "an already registered master is not registered twice")
    }

    func testExistingInstallRotatesTheMasterOnceInOrder() async throws {
        let store = defaults()
        AssistantKeyLabels.save("ab12cd34", label: "피클", period: .quarter, defaults: store)
        AssistantActivityUploadGate.markSent([], defaults: store)
        let secrets = AssistantMemorySecrets([.master: oldMaster])
        let env = environment(secrets, store)
        let ready = await AssistantRegistration.prepare(env)
        XCTAssertTrue(ready)
        let fresh = try XCTUnwrap(secrets.read(.master))
        XCTAssertNotEqual(fresh, oldMaster)
        let requests = Phase3RelayStub.requests
        XCTAssertEqual(requests.map(\.summary), [
            "POST /register", "POST /register", "DELETE /keys", "DELETE /activity", "DELETE /command", "DELETE /plan",
        ])
        XCTAssertEqual(requests.map(\.token), [fresh, oldMaster, oldMaster, oldMaster, oldMaster, oldMaster],
                       "register the new master, register the old one so it can delete, then delete with the old one")
        XCTAssertEqual(store.string(forKey: AssistantRegistration.rotationKey), AssistantRegistration.rotationTag)
        XCTAssertTrue(store.bool(forKey: AssistantRegistration.reconnectKey), "existing connections must be re-created")
        XCTAssertNil(AssistantKeyLabels.label("ab12cd34", defaults: store))

        let again = await AssistantRegistration.prepare(env)
        XCTAssertTrue(again)
        XCTAssertEqual(Phase3RelayStub.requests.count, 6, "the rollout rotation runs only once")
    }

    func testRotationKeepsTheOldMasterWhenTheNewOneIsNotRegistered() async {
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: oldMaster])
        let old = oldMaster
        let env = environment(secrets, store) { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(old)" ? 201 : 503
        }
        let ready = await AssistantRegistration.prepare(env)
        XCTAssertFalse(ready)
        XCTAssertEqual(secrets.read(.master), oldMaster)
        XCTAssertNotNil(secrets.read(.pendingMaster), "the same new key is retried next launch")
        XCTAssertFalse(Phase3RelayStub.requests.contains { $0.method == "DELETE" }, "nothing is deleted before the new master is registered")
    }

    // MARK: - 검색 키

    func testKakaoSearchUsesTheRegisteredSearchKeyNotTheMaster() async throws {
        let store = defaults()
        let secrets = AssistantMemorySecrets([.master: oldMaster])
        let env = environment(secrets, store)
        let first = await AssistantRegistration.searchToken(env)
        let token = try XCTUnwrap(first)
        XCTAssertNotEqual(token, oldMaster)
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /register"])
        XCTAssertEqual(Phase3RelayStub.requests.first?.token, token)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Phase3RelayStub.requests.first?.body)) as? [String: String])
        XCTAssertEqual(body, ["purpose": "search"])
        let second = await AssistantRegistration.searchToken(env)
        XCTAssertEqual(second, token)
        XCTAssertEqual(Phase3RelayStub.requests.count, 1)

        let request = try XCTUnwrap(MapHomeKakaoSearch.request(
            query: "카페", center: .init(latitude: 37.5, longitude: 127), nearby: true, token: token,
            endpoint: URL(string: "https://\(host)/kakao/keyword")
        ))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertTrue(request.url?.query?.contains("sort=distance") == true)
    }

    // MARK: - 클립보드

    func testKeyBearingCopiesAreLocalOnlyAndExpireInTenMinutes() throws {
        let now = at(12)
        let options = AssistantClipboard.options(now: now)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(600))
        XCTAssertEqual(AssistantClipboard.items("키")[0]["public.plain-text"] as? String, "키")
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("phase3.\(UUID().uuidString)"), create: true))
        AssistantClipboard.copy("Bearer abc", to: board, now: .now)
        XCTAssertEqual(board.string, "Bearer abc")
        UIPasteboard.remove(withName: board.name)
    }

    // MARK: - 장소 이름

    func testAddressFilterCasesFromTheReview() {
        for text in [
            "서울 강남구 테헤란로", "강남구 테헤란로", "해운대구", "울주군 삼남읍", "테헤란로", "세종대로", "역삼동",
            "渋谷区道玄坂", "道玄坂2丁目", "1600 Amphitheatre Pkwy", "1 Apple Park Way", "12 Baker Ct", "5 Rue Pl",
            "Rue de Rivoli", "Friedrichstrasse 43", "Hauptstraße 5", "테헤란로 152", "37.5, 127.0",
        ] {
            XCTAssertTrue(AssistantActivityBuilder.isAddressLike(text), text)
        }
        for text in ["스타벅스 강남역점", "홍대입구역", "홍대입구", "Blue Bottle Coffee", "롯데월드타워", "Way Cafe", "강남구청", "교보문고 광화문점"] {
            XCTAssertFalse(AssistantActivityBuilder.isAddressLike(text), text)
        }
    }

    func testSummaryRecordTitlesKeepStoreNamesAndHideAddresses() throws {
        let store = ActualRecord(planID: nil, title: "스타벅스 강남역점", categoryID: "eating", startedAt: at(9), endedAt: at(10), source: .location)
        let address = ActualRecord(planID: nil, title: "강남구 테헤란로", categoryID: "activity", startedAt: at(11), endedAt: at(12), source: .location)
        let user = ActualRecord(planID: nil, title: "강남구 테헤란로", categoryID: "activity", startedAt: at(13), endedAt: at(14), source: .manual)
        let input = AssistantActivityInput(
            day: at(0), calendar: calendar, language: .korean, categories: [], steps: nil, plansScheduled: 0, plansCompleted: 0,
            actuals: [store, address, user], categoryTitles: [:], memos: [], stays: [], travel: [], registeredNames: [:], now: at(23)
        )
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input, level: .summary))
        XCTAssertEqual(day.records.map(\.title), ["스타벅스 강남역점", "머문 곳", "강남구 테헤란로"], "only automatic location titles are filtered")
        XCTAssertNil(day.goals)
        XCTAssertNil(day.trips)
        XCTAssertNil(day.sleep)
        let json = String(decoding: try AssistantActivityUploadGate.encoder.encode(day), as: UTF8.self)
        XCTAssertFalse(json.contains("\"goals\""), "empty extra sections are left out so old hashes stay")
    }

    func testExtraReadSectionsCarryGoalsTripsAndSleepWithoutCoordinates() throws {
        let goal = PlanRecord(title: "루틴: 책 읽기", span: TimeSpan(start: at(0, day: 1), end: at(0, day: 30)), categoryID: "study")
        let sleep = ActualRecord(planID: nil, title: "수면", categoryID: "sleep", startedAt: at(0), endedAt: at(7), source: .healthKit)
        let stop = TravelPlanStop(id: UUID(), title: "경복궁", latitude: 37.58, longitude: 126.98, day: at(0), order: 0, planID: nil, status: "booked")
        let input = AssistantActivityInput(
            day: at(0), calendar: calendar, language: .korean, categories: [], steps: nil, plansScheduled: 0, plansCompleted: 0,
            actuals: [sleep], categoryTitles: [:], memos: [], stays: [], travel: [], registeredNames: [:], now: at(23),
            goals: [goal], tripStops: [stop]
        )
        let day = try XCTUnwrap(AssistantActivityBuilder.make(input, level: .summary))
        XCTAssertEqual(day.goals, [.init(id: goal.id.uuidString, title: "루틴: 책 읽기", start: "2026-11-01", end: "2026-11-29")])
        XCTAssertEqual(day.trips?.first?.items.first?.stopId, stop.id.uuidString)
        XCTAssertEqual(day.trips?.first?.items.first?.status, "booked")
        XCTAssertEqual(day.sleep?.first?.recordId, sleep.id.uuidString)
        XCTAssertEqual(day.sleep?.first?.minutes, 420)
        let json = String(decoding: try AssistantActivityUploadGate.encoder.encode(day), as: UTF8.self)
        XCTAssertFalse(json.contains("37.58") || json.contains("latitude"))
        XCTAssertNil(AssistantActivityBuilder.make(input, level: .off))
    }

    // MARK: - 연결 키

    func testCommandsFromInactiveKeysAreSkipped() throws {
        let data = try JSONSerialization.data(withJSONObject: ["commands": [
            ["format": "bokki-command", "version": 1, "id": "a", "action": "addMemo", "text": "1", "keyId": "aaaa1111", "source": "rest"],
            ["format": "bokki-command", "version": 1, "id": "b", "action": "addMemo", "text": "2", "keyId": "bbbb2222", "source": "oauth"],
            ["format": "bokki-command", "version": 1, "id": "c", "action": "addMemo", "text": "3"],
            ["format": "bokki-command", "version": 1, "id": "d", "action": "nope", "keyId": "aaaa1111"],
        ]])
        let batch = try XCTUnwrap(AssistantCommandParser.parse(data, now: at(12), calendar: calendar))
        XCTAssertEqual(batch.commands.first?.keyID, "aaaa1111")
        XCTAssertEqual(batch.commands.first?.source, "rest")
        let keys = [
            AssistantScopedKey(id: "aaaa1111", scope: .write, expiresAt: nil),
            AssistantScopedKey(id: "bbbb2222", scope: .write, expiresAt: at(1)),
        ]
        let split = AssistantKeyFilter.split(batch, active: AssistantKeyFilter.activeIDs(keys, now: at(12)))
        XCTAssertEqual(split.kept.commands.map(\.id), ["a"])
        XCTAssertEqual(split.inactiveIDs, ["b", "c"], "expired and missing keyIds are not applied")
        XCTAssertEqual(split.kept.invalidIDs, ["d"])

        let store = defaults()
        AssistantKeyLabels.save("aaaa1111", label: "피클", period: .quarter, defaults: store)
        XCTAssertEqual(AssistantConnectionName.name(keyID: "aaaa1111", source: "rest", defaults: store), "피클")
        XCTAssertEqual(AssistantConnectionName.name(keyID: "zzzz9999", source: "oauth", defaults: store), "OAuth")
    }

    // MARK: - App Store

    func testAppStoreFallbacksUseTheExactIDs() {
        XCTAssertEqual(AssistantAIProvider.chatGPT.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6448311069")
        XCTAssertEqual(AssistantAIProvider.claude.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6473753684")
        XCTAssertEqual(AssistantAIProvider.gemini.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6477489729")
        XCTAssertEqual(AssistantAIProvider.pickle.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6795790129")
        XCTAssertNil(AssistantAIProvider.other.appStoreURL)
        for provider in AssistantAIProvider.featured {
            XCTAssertEqual(provider.destination(installed: false), provider.appStoreURL)
            XCTAssertEqual(provider.destination(installed: true), provider.appURL)
            XCTAssertNotNil(provider.planBadge(.korean))
        }
        for app in TripImportAIApp.allCases { XCTAssertEqual(app.fallbackURL, app.provider.appStoreURL) }
        XCTAssertEqual(AssistantAIProvider.pickle.planBadge(.korean), "무료")
        XCTAssertEqual(AssistantAIProvider.featured, [.pickle, .chatGPT, .claude, .gemini, .cue])
    }

    func testOAuthCodeParsingCapsAtTenMinutes() {
        let now = at(12)
        XCTAssertEqual(AssistantOAuthCode.parse(Data(#"{"code":"AB12CD34","expiresIn":600}"#.utf8), now: now),
                       AssistantOAuthCode(code: "AB12CD34", expiresAt: now.addingTimeInterval(600)))
        XCTAssertEqual(AssistantOAuthCode.parse(Data(#"{"code":"AB12CD34","expiresIn":9999}"#.utf8), now: now)?.expiresAt, now.addingTimeInterval(600))
        XCTAssertNil(AssistantOAuthCode.parse(Data(#"{"nope":1}"#.utf8), now: now))
        XCTAssertFalse(TripRelay.claudeCodeCommand(host: host).contains("Bearer"), "the Claude Code command carries no key")
    }

    // MARK: - 새 명령

    private func command(_ id: String, _ action: String, _ extra: [String: Any]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": action, "keyId": "aaaa1111"].merging(extra) { $1 }
    }

    private func batch(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(15), calendar: calendar))
    }

    func testNewActionsParseAndRejectBadShapes() throws {
        let id = UUID().uuidString
        let parsed = try batch([
            command("g1", "addGoal", ["title": "책 읽기", "start": "2026-11-10", "end": "2026-11-30"]),
            command("g2", "addGoal", ["title": "책 읽기"]),
            command("g3", "updateGoal", ["goalId": id, "end": "2026-12-01"]),
            command("g4", "updateGoal", ["goalId": id]),
            command("g5", "deleteGoal", ["goalId": id]),
            command("s1", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "latitude": 37.58, "longitude": 126.98, "status": "booked"]),
            command("s2", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "latitude": 137.0, "longitude": 126.98]),
            command("s3", "updateTripStop", ["stopId": id, "order": 2]),
            command("s4", "updateTripStop", ["stopId": id, "status": "maybe"]),
            command("s5", "deleteTripStop", ["stopId": id]),
            command("s6", "setTripItemStatus", ["tripId": "t1", "itemId": "i1", "status": "tentative"]),
            command("z1", "updateSleep", ["recordId": id, "start": "23:30", "end": "07:00"]),
            command("z2", "updateSleep", ["recordId": id]),
            command("p1", "setLanguage", ["language": "ja"]),
            command("p2", "setMapStyle", ["mapStyle": "mapLibreInk"]),
            command("p3", "setTheme", ["theme": "navy"]),
            command("p4", "setDisplayOption", ["option": "mapPhotos", "enabled": false]),
            command("p5", "setDisplayOption", ["option": "backups", "enabled": false]),
            command("x1", "setShareLevel", ["level": "visits"]),
            command("x2", "deleteAllData", [:]),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["g1", "g3", "g5", "s1", "s3", "s5", "s6", "z1", "p1", "p2", "p3", "p4"])
        XCTAssertEqual(parsed.invalidIDs, ["g2", "g4", "s2", "s4", "z2", "p5", "x1", "x2"], "dangerous actions are never accepted")
        let actions = parsed.commands.map(\.action)
        XCTAssertEqual(actions[0], .addGoal(title: "책 읽기", start: at(0), end: at(0, day: 30), categoryID: nil))
        XCTAssertEqual(actions[3], .addTripStop(
            title: "경복궁", day: at(0, day: 12), coordinate: AssistantCoordinate(latitude: 37.58, longitude: 126.98), status: .booked, tripID: nil
        ))
        XCTAssertEqual(actions[7], .updateSleep(recordID: id, start: .clock(hour: 23, minute: 30), end: .clock(hour: 7, minute: 0)))
        XCTAssertEqual(actions[8], .setLanguage(.japanese))
        XCTAssertEqual(actions[10], .setMapStyle(.mapLibreNight))
        XCTAssertEqual(actions[11], .setDisplayOption(.mapPhotos, enabled: false))
        XCTAssertEqual(actions.map(\.kind), [.addGoal, .updateGoal, .deleteGoal, .addTripStop, .updateTripStop, .deleteTripStop,
                                             .setTripItemStatus, .updateSleep, .setLanguage, .setMapStyle, .setMapStyle, .setDisplayOption])
        XCTAssertEqual(actions.map(\.existingChangeCount), [0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1])
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func apply(_ model: AppModel, _ item: [String: Any], store: UserDefaults) async throws -> AssistantLogEntry {
        let applied = await model.applyAssistantCommands(try batch([item]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results.map(\.applied), [true], "\(outcome.results)")
        return try XCTUnwrap(outcome.entries.first)
    }

    private func undo(_ model: AppModel, _ entry: AssistantLogEntry, store: UserDefaults) async {
        let undone = await model.undoAssistantEntry(entry, preferences: .test(store))
        XCTAssertTrue(undone)
    }

    /// ACT1111A01: 미확인 시간은 아직 기록이 없는 부분만 채우고, 이동 수단 교정은 되돌리면 구간과 교정표가 그대로 돌아온다.
    func testClassifyUnconfirmedFillsOnlyTheGapAndTravelModeIsUndoable() async throws {
        let store = defaults()
        var seed = TaptionDataSnapshot.empty
        let work = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: at(9), endedAt: at(12), source: .location)
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: at(8, 30), end: at(9)), distanceMeters: 8_000, confidence: .medium, evidence: [])
        seed.actuals = [work]
        seed.travel = [ride]
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: seed), cloudSyncService: nil)
        await model.bootstrap()
        let category = try XCTUnwrap(model.snapshot.categories.first { $0.id != "unconfirmed" }).id

        let parsed = try batch([
            command("c0", "classifyUnconfirmed", ["date": "2026-11-10", "start": "11:00", "end": "13:00", "categoryId": category, "title": "산책"]),
            command("t0", "setTravelMode", ["date": "2026-11-10", "moveId": ride.id.uuidString, "mode": "subway"]),
            command("bad1", "classifyUnconfirmed", ["date": "2026-11-10", "start": "13:00", "end": "11:00", "categoryId": category]),
            command("bad2", "setTravelMode", ["date": "2026-11-10", "moveId": ride.id.uuidString, "mode": "other"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.action.kind), [.classifyUnconfirmed, .setTravelMode])
        XCTAssertEqual(Set(parsed.invalidIDs), ["bad1", "bad2"])

        let filled = try await apply(model, command("c1", "classifyUnconfirmed", ["date": "2026-11-10", "start": "11:00", "end": "13:00", "categoryId": category, "title": "산책"]), store: store)
        let added = model.snapshot.actuals.filter { $0.id != work.id }
        XCTAssertEqual(added.map(\.title), ["산책"])
        XCTAssertEqual(added.first?.startedAt, at(12), "업무가 덮은 11~12시는 건드리지 않는다")
        XCTAssertEqual(added.first?.endedAt, at(13))
        XCTAssertEqual(added.first?.source, .manual)
        let again = await model.applyAssistantCommands(try batch([command("c2", "classifyUnconfirmed", ["date": "2026-11-10", "start": "12:00", "end": "13:00", "categoryId": category])]), defaults: store)
        XCTAssertEqual(again?.results, [.init(id: "c2", applied: false, reason: "no_gap")], "이미 채운 시간은 미확인이 아니다")
        await undo(model, filled, store: store)
        XCTAssertEqual(model.snapshot.actuals.map(\.id), [work.id])

        let corrected = try await apply(model, command("t1", "setTravelMode", ["date": "2026-11-10", "moveId": ride.id.uuidString, "mode": "subway"]), store: store)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .subway)
        XCTAssertEqual(model.snapshot.travel.first?.isConfirmed, true)
        XCTAssertNotNil(corrected.delta.movement)
        await undo(model, corrected, store: store)
        XCTAssertEqual(model.snapshot.travel.first?.mode, .car)
        XCTAssertEqual(model.snapshot.settings.movementCorrections, seed.settings.movementCorrections)
        let missing = await model.applyAssistantCommands(try batch([command("t2", "setTravelMode", ["date": "2026-11-10", "moveId": UUID().uuidString, "mode": "bus"])]), defaults: store)
        XCTAssertEqual(missing?.results, [.init(id: "t2", applied: false, reason: "no_record")])
    }

    func testGoalAddUpdateDeleteAreUndoable() async throws {
        let store = defaults()
        let model = await makeModel()
        let added = try await apply(model, command("g1", "addGoal", ["title": "책 읽기", "start": "2026-11-10", "end": "2026-11-30"]), store: store)
        let goal = try XCTUnwrap(model.snapshot.plans.first { GoalRecordPolicy.isGoal($0) })
        XCTAssertEqual(goal.title, GoalRecordPolicy.displayTitle("책 읽기"))
        XCTAssertEqual(added.keyID, "aaaa1111")
        await undo(model, added, store: store)
        XCTAssertFalse(model.snapshot.plans.contains { GoalRecordPolicy.isGoal($0) })

        let parent = PlanRecord(title: "루틴: 운동", span: TimeSpan(start: at(0), end: at(0, day: 20)), categoryID: "exercise")
        let child = PlanRecord(title: "달리기", span: TimeSpan(start: at(7), end: at(8)), categoryID: "exercise", parentID: parent.id)
        model.snapshot.plans = [parent, child]
        let renamed = try await apply(model, command("g2", "updateGoal", ["goalId": parent.id.uuidString, "title": "운동하기"]), store: store)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == parent.id }?.title, GoalRecordPolicy.displayTitle("운동하기"))
        await undo(model, renamed, store: store)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == parent.id }?.title, "루틴: 운동")

        let deleted = try await apply(model, command("g3", "deleteGoal", ["goalId": parent.id.uuidString]), store: store)
        XCTAssertTrue(model.snapshot.plans.isEmpty, "the routine and its children are removed")
        await undo(model, deleted, store: store)
        let restoredParent = try XCTUnwrap(model.snapshot.plans.first { $0.title == "루틴: 운동" })
        let restoredChild = try XCTUnwrap(model.snapshot.plans.first { $0.title == "달리기" })
        XCTAssertEqual(restoredChild.parentID, restoredParent.id, "children follow the routine's new id")
    }

    func testTripStopAddUpdateStatusDeleteAreUndoable() async throws {
        let store = defaults()
        let model = await makeModel()
        let added = try await apply(model, command("s1", "addTripStop", ["title": "경복궁", "date": "2026-11-12", "latitude": 37.58, "longitude": 126.98]), store: store)
        let stop = try XCTUnwrap(model.snapshot.settings.travelPlanStops.first)
        XCTAssertEqual(stop.title, "경복궁")
        XCTAssertNotNil(stop.planID)
        await undo(model, added, store: store)
        XCTAssertTrue(model.snapshot.settings.travelPlanStops.isEmpty)
        XCTAssertFalse(model.snapshot.plans.contains { $0.title == "경복궁" })

        let item = TravelTripItem(tripID: "t1", itemID: "i1", kind: "sight", title: "남산", start: at(10), end: at(12),
                                  startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil)
        let pinned = TravelPlanStop(id: UUID(), title: "남산", latitude: 37.55, longitude: 126.99, day: at(0), order: 0, planID: nil, tripID: "t1", itemID: "i1")
        model.snapshot.settings.travelTripItems = [item]
        model.snapshot.settings.travelPlanStops = [pinned]
        let status = try await apply(model, command("s2", "setTripItemStatus", ["tripId": "t1", "itemId": "i1", "status": "booked"]), store: store)
        XCTAssertEqual(model.snapshot.settings.travelTripItems?.first?.status, "booked")
        XCTAssertEqual(model.snapshot.settings.travelPlanStops.first?.status, "booked")
        await undo(model, status, store: store)
        XCTAssertNil(model.snapshot.settings.travelTripItems?.first?.status)

        let renamed = try await apply(model, command("s3", "updateTripStop", ["stopId": pinned.id.uuidString, "title": "남산타워", "status": "tentative"]), store: store)
        XCTAssertEqual(model.snapshot.settings.travelPlanStops.first?.title, "남산타워")
        XCTAssertEqual(model.snapshot.settings.travelTripItems?.first?.title, "남산타워")
        XCTAssertEqual(model.snapshot.settings.travelTripItems?.first?.status, "tentative")
        await undo(model, renamed, store: store)
        XCTAssertEqual(model.snapshot.settings.travelPlanStops, [pinned])

        let removed = try await apply(model, command("s4", "deleteTripStop", ["stopId": pinned.id.uuidString]), store: store)
        XCTAssertTrue(model.snapshot.settings.travelPlanStops.isEmpty)
        await undo(model, removed, store: store)
        XCTAssertEqual(model.snapshot.settings.travelPlanStops, [pinned])
    }

    func testSleepCorrectionKeepsTheAutomaticRecordAndCanBeUndone() async throws {
        let store = defaults()
        let model = await makeModel()
        let sleep = ActualRecord(planID: nil, title: "수면", categoryID: "sleep", startedAt: at(23), endedAt: at(6, 30, day: 11),
                                 source: .healthKit, evidence: ["건강 수면"])
        model.snapshot.actuals = [sleep]
        let entry = try await apply(model, command("z", "updateSleep", [
            "recordId": sleep.id.uuidString, "start": "2026-11-10T23:30+09:00", "end": "2026-11-11T07:00+09:00",
        ]), store: store)
        let correction = try XCTUnwrap(model.snapshot.settings.activityCorrections[sleep.id])
        XCTAssertEqual(correction.startedAt, at(23, 30))
        XCTAssertEqual(correction.endedAt, at(7, day: 11))
        // 확정 수면은 표시 기록을 새 시간으로 다시 만든다(타임라인 시간 조정과 같은 경로). 원본 사본은 되돌리기에 남는다.
        let shown = try XCTUnwrap(model.snapshot.actuals.first { $0.categoryID == "sleep" })
        XCTAssertEqual(shown.startedAt, at(23, 30))
        XCTAssertEqual(shown.endedAt, at(7, day: 11))
        XCTAssertEqual(entry.delta.actuals.first { $0.id == sleep.id }?.before, sleep)
        XCTAssertFalse(entry.after.isEmpty)
        await undo(model, entry, store: store)
        XCTAssertNil(model.snapshot.settings.activityCorrections[sleep.id])
        XCTAssertEqual(model.snapshot.actuals.filter { $0.categoryID == "sleep" }, [sleep], "undo brings back the automatic record and nothing else")

        let rejected = await model.applyAssistantCommands(try batch([command("w", "updateSleep", ["recordId": UUID().uuidString, "end": "08:00"])]), defaults: store)
        XCTAssertEqual(rejected?.results, [.init(id: "w", applied: false, reason: "no_sleep")])
    }

    func testSafeSettingsAreUndoableAndStayOffTheRealDefaults() async throws {
        let store = defaults()
        let model = await makeModel()
        let before = model.snapshot.settings.mapDisplayStyle
        let style = try await apply(model, command("p1", "setMapStyle", ["mapStyle": "mapLibreInk"]), store: store)
        XCTAssertEqual(model.snapshot.settings.mapDisplayStyle, .mapLibreInk)
        await undo(model, style, store: store)
        XCTAssertEqual(model.snapshot.settings.mapDisplayStyle, before)

        let photos = try await apply(model, command("p2", "setDisplayOption", ["option": "mapPhotos", "enabled": false]), store: store)
        XCTAssertEqual(store.object(forKey: "mapHomeShowsPhotos") as? Bool, false)
        await undo(model, photos, store: store)
        XCTAssertEqual(store.object(forKey: "mapHomeShowsPhotos") as? Bool, true)

        let language = try await apply(model, command("p3", "setLanguage", ["language": "ja"]), store: store)
        XCTAssertEqual(AppLanguagePreference.load(from: store), .japanese)
        await undo(model, language, store: store)
        XCTAssertEqual(AppLanguagePreference.load(from: store), .automatic)
    }

    func testUndoRefusesWhenTheSettingChangedAfterwards() async throws {
        let store = defaults()
        let model = await makeModel()
        let entry = try await apply(model, command("p", "setDisplayOption", ["option": "mapRoutes", "enabled": false]), store: store)
        store.set(true, forKey: "mapHomeShowsRoutes")
        let undone = await model.undoAssistantEntry(entry, preferences: .test(store))
        XCTAssertFalse(undone, "a later user change wins")
    }

    // MARK: - AI 말풍선(BUB1110A01)

    func testBubbleTextRendersMarkdownLabelsAndHostsAndCountsWithoutURLs() throws {
        let text = try XCTUnwrap(AssistantBubbleText("체크인 3시! [예약증 열기](https://example.com/booking?id=1) https://maps.apple.com/?q=x"))
        XCTAssertEqual(text.display, "체크인 3시! 예약증 열기 maps.apple.com")
        XCTAssertEqual(text.links.map(\.label), ["예약증 열기", "maps.apple.com"])
        XCTAssertEqual(text.links.first?.url.absoluteString, "https://example.com/booking?id=1")

        let eighty = String(repeating: "가", count: 80)
        XCTAssertNotNil(AssistantBubbleText(eighty))
        XCTAssertNil(AssistantBubbleText(eighty + "가"), "81 characters")
        XCTAssertNotNil(AssistantBubbleText(eighty + " https://example.com/" + String(repeating: "a", count: 50)), "bare URLs don't count")
        XCTAssertNil(AssistantBubbleText(String(repeating: "가", count: 75) + " [여섯글자라벨](https://example.com)"), "labels count")
        XCTAssertNil(AssistantBubbleText("[\(String(repeating: "가", count: 21))](https://example.com)"), "labels are at most 20")
        XCTAssertNil(AssistantBubbleText("https://a.com https://b.com https://c.com https://d.com"), "at most 3 links")
        for bad in ["[열기](http://example.com)", "http://example.com", "전화 tel:0212345678", "javascript:alert(1)", "[x](javascript:alert(1))", "mailto:a@b.com", "  "] {
            XCTAssertNil(AssistantBubbleText(bad), bad)
        }
        XCTAssertNotNil(AssistantBubbleText("오늘 할 일: 3개"), "a plain colon is fine")
    }

    func testBubbleWindowSelectionHideAndDayLimit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bubbles-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let morning = AssistantBubble(start: at(9), end: at(11), text: "아침")
        let meeting = AssistantBubble(start: at(10), end: at(10, 30), text: "회의")
        XCTAssertNotNil(AssistantBubbleStore.add(morning, now: at(8), calendar: calendar, file: file))
        XCTAssertNotNil(AssistantBubbleStore.add(meeting, now: at(8), calendar: calendar, file: file))
        let all = AssistantBubbleStore.load(from: file)
        XCTAssertNil(AssistantBubbleStore.active(at: at(8, 59), in: all))
        XCTAssertEqual(AssistantBubbleStore.active(at: at(9, 30), in: all)?.text, "아침")
        XCTAssertEqual(AssistantBubbleStore.active(at: at(10, 10), in: all)?.text, "회의", "the later one wins while they overlap")
        XCTAssertNil(AssistantBubbleStore.active(at: at(11), in: all), "the end is exclusive")
        AssistantBubbleStore.hide(meeting.id, file: file)
        XCTAssertEqual(AssistantBubbleStore.active(at: at(10, 10), in: AssistantBubbleStore.load(from: file))?.text, "아침")

        for index in 2..<AssistantBubbleStore.dayLimit {
            XCTAssertNotNil(AssistantBubbleStore.add(AssistantBubble(start: at(12, index), end: at(13), text: "\(index)"), now: at(8), calendar: calendar, file: file))
        }
        XCTAssertNil(AssistantBubbleStore.add(AssistantBubble(start: at(14), end: at(15), text: "49"), now: at(8), calendar: calendar, file: file), "48 a day")
        XCTAssertNotNil(AssistantBubbleStore.add(AssistantBubble(start: at(9, day: 11), end: at(10, day: 11), text: "다음 날"), now: at(8), calendar: calendar, file: file))
    }

    /// BUB1110A02: event는 그날 하루 맨 앞, routine은 그 시간대. 지난 event만 지우고 routine은 남긴다.
    func testBubbleKindsPriorityAndExpiry() throws {
        let parsed = try batch([
            command("e1", "setBubble", ["date": "2026-11-10", "kind": "event", "text": "여권 챙기세요"]),
            command("r1", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": "출근길 조심"]),
            command("x1", "setBubble", ["date": "2026-11-10", "kind": "nightly", "start": "09:00", "end": "10:00", "text": "?"]),
            command("r2", "setBubble", ["date": "2026-11-10", "text": "시간대 없음"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.action), [
            .setBubble(start: at(0), end: at(0, day: 11), text: "여권 챙기세요", kind: .event),
            .setBubble(start: at(9), end: at(10), text: "출근길 조심"),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["x1", "r2"])

        let event = AssistantBubble(start: at(0), end: at(0, day: 11), text: "여권 챙기세요", kind: .event)
        let routine = AssistantBubble(start: at(9), end: at(10), text: "출근길 조심")
        XCTAssertEqual(AssistantBubbleStore.active(at: at(9, 30), in: [routine, event])?.id, event.id, "the day's event comes first")
        XCTAssertNil(AssistantBubbleStore.active(at: at(9, 30), in: [AssistantBubble(start: at(0), end: at(0, day: 11), text: "x", hidden: true, kind: .event)]))
        XCTAssertEqual(AssistantBubbleStore.active(at: at(9, 30), in: [routine])?.id, routine.id)

        XCTAssertFalse(AssistantBubbleStore.isExpired(event, now: at(23, 59), calendar: calendar))
        XCTAssertTrue(AssistantBubbleStore.isExpired(event, now: at(0, 1, day: 11), calendar: calendar), "gone after its day")
        XCTAssertFalse(AssistantBubbleStore.isExpired(routine, now: at(9, day: 30), calendar: calendar), "routine bubbles are kept")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bubbles-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        AssistantBubbleStore.save([event, routine], to: file)
        AssistantBubbleStore.cleanExpired(now: at(8, day: 12), calendar: calendar, file: file)
        XCTAssertEqual(AssistantBubbleStore.load(from: file).map(\.id), [routine.id])
    }

    func testOldBubbleFilesStillDecodeAsRoutine() throws {
        let old = #"[{"id":"7E2C3F0A-7E1D-4F2A-9C77-1B9F0F0E0A11","start":0,"end":3600,"text":"예전","hidden":false}]"#
        let bubbles = try JSONDecoder().decode([AssistantBubble].self, from: Data(old.utf8))
        XCTAssertEqual(bubbles.first?.kind, .routine)
        XCTAssertNil(bubbles.first?.createdAt)
    }

    func testDefaultBubblePoolIsStablePerHalfHour() {
        let time = at(10, 5)
        let first = MapHomeDefaultBubblePool.phrase(for: .computer, at: time, language: .korean)
        XCTAssertNotNil(first)
        XCTAssertEqual(MapHomeDefaultBubblePool.phrase(for: .computer, at: at(10, 20), language: .korean), first, "same half hour, same words")
        XCTAssertTrue(MapHomeDefaultBubblePool.phrases(.work, language: .korean).contains(first ?? ""))
        XCTAssertEqual(MapHomeDefaultBubblePool.group(for: .car), .movement)
        XCTAssertEqual(MapHomeDefaultBubblePool.group(for: .eating), .eating)
        XCTAssertEqual(MapHomeDefaultBubblePool.group(for: .deepSleep), .sleep)
        XCTAssertNil(MapHomeDefaultBubblePool.phrase(for: .unconfirmed, at: time, language: .korean), "unknown activity keeps its own name")
        let day = (0..<48).compactMap { MapHomeDefaultBubblePool.phrase(for: .restDonut, at: at(0).addingTimeInterval(Double($0) * 1_800), language: .korean) }
        XCTAssertEqual(Set(day).count, MapHomeDefaultBubblePool.phrases(.rest, language: .korean).count, "every phrase comes up during a day")
    }

    func testBubbleCommandIsUndoableTogglableAndTouchesNoRecords() async throws {
        let store = defaults()
        let file = AssistantPreferenceStore.test(store).bubbleFile
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let parsed = try batch([
            command("b1", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": "[예약증](https://example.com)"]),
            command("b2", "setBubble", ["date": "2026-11-10", "start": "10:00", "end": "09:00", "text": "거꾸로"]),
            command("b3", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": "tel:01012345678"]),
        ])
        XCTAssertEqual(parsed.commands.map(\.action), [.setBubble(start: at(9), end: at(10), text: "[예약증](https://example.com)")])
        XCTAssertEqual(parsed.invalidIDs, ["b2", "b3"])
        XCTAssertEqual(parsed.commands.first?.action.existingChangeCount, 0, "bubbles don't count toward the confirm threshold")

        let model = await makeModel()
        let walk = ActualRecord(planID: nil, title: "걷기", categoryID: "movement", startedAt: at(9), endedAt: at(10), source: .motion)
        model.snapshot.actuals = [walk]
        let before = model.snapshot
        let entry = try await apply(model, command("b1", "setBubble", ["date": "2026-11-10", "start": "09:00", "end": "10:00", "text": "[예약증](https://example.com)"]), store: store)
        XCTAssertEqual(model.snapshot, before, "records and settings are unchanged")
        XCTAssertEqual(AssistantBubbleStore.load(from: file).map(\.text), ["[예약증](https://example.com)"])
        XCTAssertEqual(entry.kind, .setBubble)
        await undo(model, entry, store: store)
        XCTAssertTrue(AssistantBubbleStore.load(from: file).isEmpty, "undo removes the bubble")

        AssistantActionToggles.set(.setBubble, enabled: false, defaults: store)
        let off = await model.applyAssistantCommands(parsed, defaults: store)
        XCTAssertEqual(off?.results.filter { $0.id == "b1" }, [.init(id: "b1", applied: false, reason: "disabled")])
        XCTAssertTrue(AssistantBubbleStore.load(from: file).isEmpty)
    }

    /// 연결된 AI에게 맡긴 메모는 목록으로 올리고, AI가 고쳐 보내면 빠진다(MEM1110A02).
    func testPolishQueueUploadsTheListAndEmptiesIt() async throws {
        let store = defaults()
        store.set(["k1": "피클"], forKey: AssistantKeyLabels.labelsKey)
        XCTAssertTrue(MemoPolishQueue.hasConnection(store))
        // OAC1113A01: 이름표 없이 서버만 아는 연결(Claude 커넥터)도 연결로 본다.
        let oauthOnly = defaults()
        XCTAssertFalse(MemoPolishQueue.hasConnection(oauthOnly))
        oauthOnly.set(1, forKey: AssistantKeyLabels.serverCountKey)
        XCTAssertTrue(MemoPolishQueue.hasConnection(oauthOnly))
        XCTAssertEqual(AssistantKeyLabels.connectionCount(oauthOnly), 1)
        XCTAssertTrue(AITaskQueue.enqueue(.other, text: "넘긴 일", defaults: oauthOnly))
        AssistantKeyLabels.removeAll(defaults: oauthOnly)
        XCTAssertFalse(MemoPolishQueue.hasConnection(oauthOnly), "연결을 모두 지우면 다시 없음")
        let id = UUID()
        XCTAssertFalse(MemoPolishQueue.enqueue(id, text: "  ", day: nil, defaults: store), "empty text is not queued")
        XCTAssertTrue(MemoPolishQueue.enqueue(id, text: "회의 잘끝남", day: nil, defaults: store))
        XCTAssertTrue(MemoPolishQueue.enqueue(id, text: "회의 잘 끝남", day: nil, defaults: store))
        XCTAssertEqual(MemoPolishQueue.items(store).map(\.text), ["회의 잘 끝남"], "the same memo is replaced, not duplicated")

        let env = environment(AssistantMemorySecrets([.master: oldMaster]), store)
        await MemoPolishQueue.upload(env: env)
        let sent = try XCTUnwrap(Phase3RelayStub.requests.last)
        XCTAssertEqual(sent.summary, "POST /polish")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["format"] as? String, "bokki-polish")
        XCTAssertEqual((body["memos"] as? [[String: String]])?.first?["id"], id.uuidString)
        XCTAssertFalse(store.bool(forKey: MemoPolishQueue.needsUploadKey))

        MemoPolishQueue.resolve(id, defaults: store)
        await MemoPolishQueue.upload(env: env)
        XCTAssertEqual(Phase3RelayStub.requests.last?.summary, "DELETE /polish", "an empty list deletes the server copy")
    }

    /// 웹 요청 AI에는 키가 든 안내 대신 1회용 주소만 복사한다(SET1110A01).
    func testSetupLinkReplacesTheKeyInTheClipboardText() async throws {
        let store = defaults()
        let env = environment(AssistantMemorySecrets([.master: oldMaster]), store)
        Phase3RelayStub.body = #"{"ok":true,"code":"ABCDEFGHJK","url":"https://\#(host)/s/ABCDEFGHJK","expiresInSeconds":600}"#
        let made = await TripRelay.setupLinkText(for: "secret setup with key", env: env)
        let text = try XCTUnwrap(made)
        XCTAssertTrue(text.contains("https://\(host)/s/ABCDEFGHJK"))
        XCTAssertFalse(text.contains("secret"), "the key-bearing text is not in the clipboard text")
        let sent = try XCTUnwrap(Phase3RelayStub.requests.last)
        XCTAssertEqual(sent.summary, "POST /setup")
        XCTAssertEqual(sent.token, oldMaster)

        // 다른 곳을 가리키는 주소는 믿지 않고 전체 안내로 돌아간다.
        Phase3RelayStub.body = #"{"url":"https://evil.example/s/ABCDEFGHJK"}"#
        let refused = await TripRelay.setupLinkText(for: "x", env: env)
        XCTAssertNil(refused)
    }

    /// Cue 연결(CUE1110A01): 새 32바이트 키를 43자로, 고른 권한·기간으로 `POST /keys`에 올리고 주 키는 몸통에 넣지 않는다.
    func testCueKeyIsANewScopedKeyAndNeverTheMaster() async throws {
        var seen = Set<String>()
        for _ in 0..<50 {
            let token = try XCTUnwrap(TripRelay.randomToken())
            XCTAssertEqual(token.count, 43)
            XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "base64url without padding")
            XCTAssertTrue(TripRelay.isValidKey(token))
            seen.insert(token)
        }
        XCTAssertEqual(seen.count, 50, "keys don't repeat")

        let store = defaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let env = environment(AssistantMemorySecrets([.master: oldMaster]), store)
        let made = await TripRelay.registerScopedKey(label: "Cue", scope: .read, period: .month, pin: "135790", provider: .cue, now: now, env: env)
        guard case let .created(key, token) = made else { return XCTFail("\(made)") }
        XCTAssertNotEqual(token, oldMaster)
        XCTAssertEqual(key.scope, .read)
        XCTAssertEqual(key.expiresAt, now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(AssistantKeyProviders.provider(key.id, defaults: store), .cue)
        let sent = try XCTUnwrap(Phase3RelayStub.requests.last)
        XCTAssertEqual(sent.summary, "POST /keys")
        XCTAssertEqual(sent.token, oldMaster, "the master key only goes in the app's own Authorization header")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let keys = try XCTUnwrap(body["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0]["token"] as? String, token)
        XCTAssertEqual(keys[0]["scope"] as? String, "read")
        XCTAssertEqual(keys[0]["expiresAt"] as? String, TripRelay.isoText(now.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(body["pin"] as? String, "135790")
        XCTAssertFalse(String(decoding: sent.body, as: UTF8.self).contains(oldMaster), "the master key is never in the body")

        // 거절은 이유별 문구로, 응답이 없으면 실패로 돌려준다.
        let locked = environment(AssistantMemorySecrets([.master: oldMaster]), store) { _ in 423 }
        Phase3RelayStub.body = #"{"error":"pin_locked","retryAfter":900}"#
        guard case let .refused(refusal) = await TripRelay.registerScopedKey(label: "Cue", scope: .write, period: .never, pin: "135790", provider: .cue, env: locked)
        else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.kind, .locked)
    }

    func testCueScreenTextAndDisconnectWarning() {
        XCTAssertEqual(AssistantAIProvider.cue.title(.korean), "Cue")
        XCTAssertEqual(AssistantAIProvider.cue.appStoreURL?.absoluteString, "https://apps.apple.com/app/id6808613358", "Cue by Manus")
        XCTAssertNil(AssistantAIProvider.cue.appURL, "no unverified deep link")
        let setup = TripRelay.cueSetupText(host: "trip.bokkiyaw.com", key: "K", scope: .read, expiresAt: nil)
        XCTAssertTrue(setup.contains("https://trip.bokkiyaw.com/mcp and the request header Authorization: Bearer K"))
        XCTAssertTrue(setup.contains("https://trip.bokkiyaw.com/mcp/K"))
        XCTAssertFalse(AssistantAIProvider.cue.usesOAuth)
        // CUE1111A01: 이미 연결된 Cue는 「열기」(App Store 화면에서 열기), 무료 표시.
        XCTAssertEqual(AssistantAIProvider.cue.planBadge(.korean), "무료")
        XCTAssertTrue(AssistantAIProvider.cue.isFreePlan)
        let connected = AssistantAIProvider.cue.openButton(installed: false, connected: true)
        XCTAssertTrue(connected.isOpen)
        XCTAssertEqual(connected.url, AssistantAIProvider.cue.appStoreURL)
        XCTAssertFalse(AssistantAIProvider.cue.openButton(installed: false, connected: false).isOpen)
        XCTAssertEqual(AssistantAIProvider.claude.openButton(installed: true, connected: false).url, AssistantAIProvider.claude.appURL)
        XCTAssertEqual(TripRelay.mcpURL(host: "trip.bokkiyaw.com"), "https://trip.bokkiyaw.com/mcp")
        let token = String(repeating: "a", count: 39) + "WXYZ"
        XCTAssertEqual(AssistantCueText.masked(token), "aaaa…WXYZ", "only the ends are shown")
        XCTAssertTrue(AssistantKeyText.revokeWarning("Cue", language: .korean).contains("아직 앱에 반영되지 않은 명령도 함께 지워져요"))
    }

    func testAIEditMarkShowsOnlyWhileTheTextIsTheAIText() {
        let store = defaults()
        let id = UUID()
        MemoAIEditMarks.set(id, by: "피클", text: "다듬은 글", defaults: store)
        XCTAssertEqual(MemoAIEditMarks.mark(for: id, text: "다듬은 글", defaults: store)?.by, "피클")
        XCTAssertNil(MemoAIEditMarks.mark(for: id, text: "내가 또 고침", defaults: store), "a later edit by the user hides the mark")
        XCTAssertEqual(MemoAIEditMarks.text(.init(by: "피클", at: .now, text: ""), language: .korean), "AI가 수정함 · 피클")
        MemoAIEditMarks.clear(id, defaults: store)
        XCTAssertNil(MemoAIEditMarks.all(store)[id.uuidString])
    }

    /// GDE1111A01: AI마다 단계가 있고, Claude는 코드와 PIN을 따로 복사하며, 기억은 30분 뒤 잊는다.
    @MainActor
    func testConnectGuideStepsAndMemory() {
        let claude = AssistantGuidePlan.steps(.claude, host: "trip.bokkiyaw.com", token: nil, code: "PWCQM6U9", pin: "523408", language: .korean)
        XCTAssertEqual(claude.map(\.id), ["code", "open", "copyCode", "copyPIN", "check"])
        XCTAssertEqual(claude[2].action, .copy("PWCQM6U9"))
        XCTAssertEqual(claude[3].action, .copy("523408"), "the PIN is its own step after the code")
        let waiting = AssistantGuidePlan.steps(.claude, host: "trip.bokkiyaw.com", token: nil, code: nil, pin: nil, language: .korean)
        XCTAssertNil(waiting[2].action, "no code yet, so the copy step waits")
        let gpt = AssistantGuidePlan.steps(.chatGPT, host: "trip.bokkiyaw.com", token: "K", code: nil, pin: nil, language: .korean)
        XCTAssertEqual(gpt.map(\.id), ["key", "open", "schema", "auth", "check"])
        XCTAssertEqual(gpt[2].action, .copy("https://trip.bokkiyaw.com/openapi.json"))
        XCTAssertEqual(gpt[3].action, .copy("K"))
        XCTAssertEqual(AssistantGuidePlan.steps(.pickle, host: "h", token: nil, code: nil, pin: nil, language: .korean).first?.action, .makeKey)

        let memory = AssistantGuideMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        memory.begin(.claude, now: now)
        memory.go(to: 3, now: now)
        memory.begin(.claude, now: now.addingTimeInterval(60))
        XCTAssertEqual(memory.step(for: .claude, now: now.addingTimeInterval(60)), 3, "coming back from Claude keeps the step")
        XCTAssertEqual(memory.step(for: .chatGPT, now: now.addingTimeInterval(60)), 0)
        XCTAssertNil(memory.activeProvider(now: now.addingTimeInterval(31 * 60)), "forgotten after 30 minutes")
        memory.end()
        XCTAssertNil(memory.activeProvider(now: now))
    }

    func testPasteGuideNamesWhereToPaste() {
        let korean = MapHomeLanguage.korean
        XCTAssertTrue(AssistantPasteGuide.message(.pickle, korean).contains("피클 채팅창에 붙여 넣고"))
        XCTAssertTrue(AssistantPasteGuide.message(.gemini, korean).contains("settings.json"))
        XCTAssertTrue(AssistantPasteGuide.message(.other, korean).contains("웹 요청"))
        XCTAssertTrue(AssistantPasteGuide.message(.claude, korean).contains("로그인 없음"), "Claude gets the one-link connector steps")
        XCTAssertTrue(AssistantPasteGuide.message(.chatGPT, korean).contains("Bearer"), "ChatGPT gets the custom GPT key steps")
        XCTAssertEqual(TripRelay.openAPIURL(host: "trip.bokkiyaw.com"), "https://trip.bokkiyaw.com/openapi.json")
        XCTAssertEqual(AssistantAIProvider.chatGPT.planBadge(korean), "유료 · 맞춤 GPT는 Plus 이상")
        XCTAssertEqual(TripRelay.mcpKeyURL(host: "relay.example.com", key: "K"), "https://relay.example.com/mcp/K")
        let add = try? XCTUnwrap(TripRelay.claudeAddConnectorURL(host: "trip.bokkiyaw.com"))
        XCTAssertEqual(add?.host(), "claude.ai")
        let items = URLComponents(url: add!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "modal" }?.value, "add-custom-connector")
        XCTAssertEqual(items.first { $0.name == "connectorUrl" }?.value, "https://trip.bokkiyaw.com/mcp", "no key in the link; approval runs on OAuth")
    }

    func testCurrentPINRequiredIsNotPINNotSet() {
        let refusal = AssistantServerRefusal.parse(status: 422, data: Data(#"{"error":"current_pin_required"}"#.utf8))
        XCTAssertEqual(refusal?.kind, .currentPINRequired)
        XCTAssertEqual(AssistantServerRefusal.parse(status: 503, data: Data(#"{"error":"pin_check_unavailable"}"#.utf8))?.kind, .unavailable)
        // 옛 서버는 /pin을 몰라 404 not_found를 준다(아이폰 18, 2026-11-10).
        XCTAssertEqual(AssistantServerRefusal.parse(status: 404, data: Data(#"{"error":"not_found"}"#.utf8))?.kind, .serverOutdated)
    }

    func testOldLogEntriesStillDecode() throws {
        let old = #"[{"id":"7E2C3F0A-7E1D-4F2A-9C77-1B9F0F0E0A11","commandID":"x","kind":"addMemo","appliedAt":0,"before":"","after":"메모","delta":{"plans":[],"memos":[],"actuals":[],"corrections":[],"addedSleepSpans":[],"removedSleepSpans":[]}}]"#
        let entries = try JSONDecoder().decode([AssistantLogEntry].self, from: Data(old.utf8))
        XCTAssertNil(entries.first?.keyID)
        XCTAssertNil(entries.first?.delta.travel)
        XCTAssertNil(entries.first?.delta.preferences)
    }
}

/// 시험용 메모리 보관(키체인 대신).
@MainActor
final class AssistantMemorySecrets: AssistantSecretStore {
    var values: [AssistantSecretSlot: String] = [:]

    init(_ values: [AssistantSecretSlot: String] = [:]) { self.values = values }

    func read(_ slot: AssistantSecretSlot) -> String? { values[slot] }

    @discardableResult
    func write(_ value: String?, to slot: AssistantSecretSlot) -> Bool {
        values[slot] = value
        return true
    }
}

/// 중계 요청을 차례로 적는다.
final class Phase3RelayStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var path: String
        var token: String?
        var body: Data

        var summary: String { "\(method) \(path)" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [Seen] = []
    nonisolated(unsafe) private static var status: @Sendable (URLRequest) -> Int = { _ in 201 }
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var retryAfter: String?

    static var requests: [Seen] { lock.withLock { seen } }

    static func reset(status: @escaping (URLRequest) -> Int) {
        let box = UncheckedStatus(status)
        lock.withLock {
            seen = []
            body = "{}"
            retryAfter = nil
            self.status = { box.value($0) }
        }
    }

    private final class UncheckedStatus: @unchecked Sendable {
        let value: (URLRequest) -> Int
        init(_ value: @escaping (URLRequest) -> Int) { self.value = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        let (code, reply, retry): (Int, String, String?) = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", token: token, body: body))
            return (Self.status(request), Self.body, Self.retryAfter)
        }
        var headers = ["Content-Type": "application/json"]
        if let retry { headers["Retry-After"] = retry }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// PRL1112A01: AI가 보태는 결제 문자 읽기 규칙. 명령 읽기·검사·적용·되돌리기.
@MainActor
final class AssistantPaymentRuleTests: XCTestCase {
    private let sample = "[OO카드] 승인 홍*동 12,300원 11/12 08:10 스타벅스"
    private let pattern = #"\[OO카드\] 승인 \S+ (?<amount>[\d,]+)원 (?<month>\d{1,2})/(?<day>\d{1,2}) (?<hour>\d{1,2}):(?<minute>\d{2}) (?<merchant>.+)"#

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(year: Int = 2026, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantPaymentRuleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func command(_ id: String, _ extra: [String: Any]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": "addPaymentRule", "name": "OO카드"].merging(extra) { $1 }
    }

    private func batch(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(11, 12, 9), calendar: calendar))
    }

    private func rule(_ name: String = "OO카드", _ pattern: String? = nil, kind: LedgerMessageRules.Kind = .expense) throws -> LedgerMessageRules.Rule {
        try LedgerMessageRules.validated(name: name, pattern: pattern ?? self.pattern, sample: sample, kind: kind).get()
    }

    func testCommandParsesToRuleAndRejectsBadRules() throws {
        let parsed = try batch([
            command("ok", ["pattern": pattern, "sample": sample]),
            command("ignore", ["pattern": "OO카드", "sample": sample, "kind": "ignore"]),
            command("badRegex", ["pattern": "(?<amount>[0-9", "sample": sample]),
            command("noMatch", ["pattern": "XX카드 (?<amount>[0-9,]+)원", "sample": sample]),
            command("noAmount", ["pattern": "OO카드", "sample": sample]),
            command("badKind", ["pattern": pattern, "sample": sample, "kind": "refund"]),
            command("noSample", ["pattern": pattern]),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["ok", "ignore"])
        XCTAssertEqual(parsed.commands.map(\.action.kind), [.addPaymentRule, .addPaymentRule])
        XCTAssertEqual(Set(parsed.invalidIDs), ["badRegex", "noMatch", "noAmount", "badKind", "noSample"])
        guard case let .addPaymentRule(first) = parsed.commands[0].action, case let .addPaymentRule(second) = parsed.commands[1].action else {
            return XCTFail("\(parsed)")
        }
        XCTAssertEqual([first.name, first.pattern, first.sample], ["OO카드", pattern, sample])
        XCTAssertEqual(first.kind, .expense, "kind가 없으면 지출")
        XCTAssertEqual(second.kind, .ignore)
        XCTAssertEqual(parsed.commands[0].action.existingChangeCount, 0)
    }

    func testValidationNamesTheFailure() {
        func failure(_ pattern: String, sample: String? = nil, kind: LedgerMessageRules.Kind = .expense) -> LedgerMessageRules.Failure? {
            if case let .failure(reason) = LedgerMessageRules.validated(name: "OO카드", pattern: pattern, sample: sample ?? self.sample, kind: kind) { return reason }
            return nil
        }
        XCTAssertNil(failure(pattern))
        XCTAssertEqual(failure("(?<amount>[0-9"), .badPattern)
        XCTAssertEqual(failure("XX카드 (?<amount>[0-9,]+)원"), .noMatch)
        XCTAssertEqual(failure("OO카드"), .noAmount)
        XCTAssertEqual(failure("(?<amount>승인)"), .noAmount, "숫자가 아닌 금액")
        XCTAssertNil(failure("OO카드", kind: .ignore), "넣지 않는 규칙은 금액이 없어도 된다")
        XCTAssertEqual(failure(String(repeating: "a", count: 301)), .tooLong)
        XCTAssertEqual(failure(pattern, sample: ""), .tooLong)
    }

    func testRuleReadsAmountMerchantAndDate() throws {
        let store = defaults()
        XCTAssertNil(LedgerMessageRules.match(sample, now: at(11, 12, 9), calendar: calendar, defaults: store))
        LedgerMessageRules.add(try rule(), defaults: store)
        guard case let .draft(draft, income) = LedgerMessageRules.match(sample, now: at(11, 12, 9), calendar: calendar, defaults: store) else {
            return XCTFail("규칙이 견본을 읽어야 한다")
        }
        XCTAssertFalse(income)
        XCTAssertEqual(draft.amount, 12_300)
        XCTAssertEqual(draft.currency, "KRW")
        XCTAssertEqual(draft.merchant, "스타벅스")
        XCTAssertEqual(draft.card, "OO카드")
        XCTAssertEqual(draft.occurredAt, at(11, 12, 8, 10))
        XCTAssertFalse(draft.isCancel)

        // 해를 넘긴 문자는 작년으로 읽는다.
        guard case let .draft(old, _) = LedgerMessageRules.match(sample, now: at(1, 5, 9), calendar: calendar, defaults: store) else { return XCTFail() }
        XCTAssertEqual(old.occurredAt, at(year: 2025, 11, 12, 8, 10))
        XCTAssertNil(LedgerMessageRules.match("[XX은행] 입금 5,000원", now: at(11, 12, 9), calendar: calendar, defaults: store))
    }

    func testIgnoreIncomeAndNewestRuleWins() throws {
        let store = defaults()
        LedgerMessageRules.add(try rule("먼저"), defaults: store)
        LedgerMessageRules.add(try rule("수입", #"OO카드\] 승인 \S+ (?<amount>[\d,]+)원"#, kind: .income), defaults: store)
        guard case let .draft(draft, income) = LedgerMessageRules.match(sample, now: at(11, 12, 9), calendar: calendar, defaults: store) else { return XCTFail() }
        XCTAssertTrue(income)
        XCTAssertEqual(draft.card, "수입", "나중에 넣은 규칙이 먼저다")
        XCTAssertNil(draft.occurredAt, "월·일·시·분이 없으면 시각을 짓지 않는다")

        LedgerMessageRules.add(try rule("무시", "OO카드", kind: .ignore), defaults: store)
        XCTAssertEqual(LedgerMessageRules.match(sample, now: at(11, 12, 9), calendar: calendar, defaults: store), .ignore)
    }

    func testRulesKeepTheNewestTwentyAndReplaceTheSamePattern() throws {
        let store = defaults()
        for index in 0...LedgerMessageRules.limit {
            LedgerMessageRules.add(try rule("규칙\(index)", "(?<amount>[0-9,]+)원.{0,\(index + 1)}"), defaults: store)
        }
        let kept = LedgerMessageRules.rules(store)
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first?.name, "규칙1", "넘치면 오래된 것부터 버린다")
        XCTAssertEqual(kept.last?.name, "규칙20")

        LedgerMessageRules.add(try rule("바꿈", kept[5].pattern), defaults: store)
        XCTAssertEqual(LedgerMessageRules.rules(store).count, 20)
        XCTAssertEqual(LedgerMessageRules.rules(store).last?.name, "바꿈")
        LedgerMessageRules.remove(try XCTUnwrap(LedgerMessageRules.rules(store).last).id, defaults: store)
        XCTAssertEqual(LedgerMessageRules.rules(store).count, 19)
    }

    func testCommandAddsTheRuleAndUndoRemovesIt() async throws {
        let store = defaults()
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let applied = await model.applyAssistantCommands(try batch([command("p1", ["pattern": pattern, "sample": sample])]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results, [.init(id: "p1", applied: true, reason: nil)])
        let entry = try XCTUnwrap(outcome.entries.first)
        XCTAssertEqual(entry.kind, .addPaymentRule)
        XCTAssertEqual(entry.after, "OO카드")
        XCTAssertEqual(LedgerMessageRules.rules(store).map(\.id), [try XCTUnwrap(entry.delta.paymentRuleID)])

        let undone = await model.undoAssistantEntry(entry, preferences: .test(store))
        XCTAssertTrue(undone)
        XCTAssertTrue(LedgerMessageRules.rules(store).isEmpty)

        AssistantActionToggles.set(.addPaymentRule, enabled: false, defaults: store)
        let refused = await model.applyAssistantCommands(try batch([command("p2", ["pattern": pattern, "sample": sample])]), defaults: store)
        XCTAssertEqual(refused?.results, [.init(id: "p2", applied: false, reason: "disabled")])
        XCTAssertTrue(LedgerMessageRules.rules(store).isEmpty)
    }
}

/// ACX1112A01: AI가 읽는 앱 상태와 가계부 설정·정리·화면 열기 명령. 읽기·검사·적용·되돌리기.
@MainActor
final class AssistantAppControlTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantAppControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func command(_ id: String, _ action: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["format": "bokki-command", "version": 1, "id": id, "action": action].merging(extra) { $1 }
    }

    private func batch(_ items: [[String: Any]]) throws -> AssistantCommandBatch {
        let data = try JSONSerialization.data(withJSONObject: ["commands": items])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(11, 12, 9), calendar: calendar))
    }

    private func model() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func logEntry(_ kind: AssistantActionKind, _ result: AssistantEditResult) -> AssistantLogEntry {
        var delta = AssistantEditDelta()
        delta.appChange = result.appChange
        delta.ledgerEntryID = result.ledgerEntryID
        delta.ledgerEntry = result.ledgerEntry
        return AssistantLogEntry(commandID: UUID().uuidString, kind: kind, appliedAt: .now, before: result.before, after: result.after, delta: delta)
    }

    private let id = "A1B2C3D4-E5F6-4789-9ABC-DEF012345678"

    func testCommandsParseWithTheServerRules() throws {
        let parsed = try batch([
            command("budget", "setBudget", ["amountKRW": 500_000]),
            command("budgetMonth", "setBudget", ["amountKRW": 0, "month": "2026-12"]),
            command("add", "addOwnAccount", ["name": " 비상금 통장 "]),
            command("remove", "removeOwnAccount", ["name": "비상금 통장"]),
            command("rule", "deletePaymentRule", ["ruleId": id]),
            command("keep", "resolveReview", ["reviewId": id, "decision": "add"]),
            command("drop", "resolveReview", ["reviewId": id, "decision": "discard"]),
            command("inbox", "deleteInboxItem", ["inboxId": id]),
            command("screen", "openScreen", ["screen": "paymentAutomation"]),
            command("negative", "setBudget", ["amountKRW": -1]),
            command("huge", "setBudget", ["amountKRW": 1e12 + 1]),
            command("noAmount", "setBudget", ["month": "2026-11"]),
            command("badMonth", "setBudget", ["amountKRW": 1, "month": "2026-13"]),
            command("shortMonth", "setBudget", ["amountKRW": 1, "month": "2026-1"]),
            command("signedMonth", "setBudget", ["amountKRW": 1, "month": "2026-+1"]),
            command("oneLetter", "addOwnAccount", ["name": " 가 "]),
            command("longName", "addOwnAccount", ["name": String(repeating: "가", count: 31)]),
            command("number", "addOwnAccount", ["name": "110-123-456789"]),
            command("spacedNumber", "removeOwnAccount", ["name": "통장 1234 5678 9012"]),
            command("badRule", "deletePaymentRule", ["ruleId": "all"]),
            command("badDecision", "resolveReview", ["reviewId": id, "decision": "delete"]),
            command("noDecision", "resolveReview", ["reviewId": id]),
            command("badInbox", "deleteInboxItem", ["inboxId": "1"]),
            command("badScreen", "openScreen", ["screen": "backupPin"]),
            command("noScreen", "openScreen"),
        ])
        XCTAssertEqual(parsed.commands.map(\.id), ["budget", "budgetMonth", "add", "remove", "rule", "keep", "drop", "inbox", "screen"])
        XCTAssertEqual(parsed.commands.map(\.action.kind), [
            .setBudget, .setBudget, .addOwnAccount, .removeOwnAccount, .deletePaymentRule, .resolveReview, .resolveReview, .deleteInboxItem, .openScreen,
        ])
        XCTAssertEqual(parsed.invalidIDs.count, 16)
        let uuid = try XCTUnwrap(UUID(uuidString: id))
        XCTAssertEqual(parsed.commands.map(\.action), [
            // 달을 주지 않으면 명령을 읽는 때의 이번 달이다.
            .setBudget(month: LedgerBook.monthKey(.now, calendar: calendar), amountKRW: 500_000), .setBudget(month: "2026-12", amountKRW: 0),
            .addOwnAccount("비상금 통장"), .removeOwnAccount("비상금 통장"), .deletePaymentRule(uuid),
            .resolveReview(uuid, add: true), .resolveReview(uuid, add: false), .deleteInboxItem(uuid), .openScreen(.paymentAutomation),
        ])
        // 더하기와 화면 열기는 기존 것을 바꾸지 않는다. 지우기·버리기·예산은 20개 확인 규칙에 센다.
        XCTAssertEqual(parsed.commands.map(\.action.existingChangeCount), [1, 1, 0, 1, 1, 1, 1, 1, 0])
        XCTAssertEqual(Set(AssistantScreen.allCases.map(\.rawValue)), ["paymentAutomation", "shortcuts", "aiConnection", "ledger", "dataProtection", "settings", "salary", "carAudio", "alarm", "placeBook", "passport", "unconfirmedReview", "travel"])
    }

    func testOwnAccountsRuleAndInboxCommandsApplyAndUndo() async throws {
        let store = defaults()
        let model = await model()
        LedgerOwnAccounts.set(["월급 통장"], defaults: store)
        let rule = try LedgerMessageRules.validated(name: "OO카드", pattern: "OO카드 (?<amount>[0-9,]+)원", sample: "OO카드 1,000원", kind: .expense).get()
        LedgerMessageRules.add(rule, defaults: store)
        PaymentInbox.record("OO카드 1,000원", outcome: .unread, message: "읽지 못함", defaults: store)
        let inboxID = try XCTUnwrap(PaymentInbox.items(store).first?.id)

        let applied = await model.applyAssistantCommands(try batch([
            command("a1", "addOwnAccount", ["name": "비상금 통장"]),
            command("a2", "addOwnAccount", ["name": "비상금 통장"]),
            command("a3", "removeOwnAccount", ["name": "월급 통장"]),
            command("a4", "removeOwnAccount", ["name": "없는 통장"]),
            command("r1", "deletePaymentRule", ["ruleId": rule.id.uuidString]),
            command("r2", "deletePaymentRule", ["ruleId": rule.id.uuidString]),
            command("i1", "deleteInboxItem", ["inboxId": inboxID.uuidString]),
            command("i2", "deleteInboxItem", ["inboxId": inboxID.uuidString]),
        ]), defaults: store)
        let outcome = try XCTUnwrap(applied)
        XCTAssertEqual(outcome.results.map(\.reason), [nil, "no_change", nil, "no_account", nil, "no_rule", nil, "no_inbox_item"])
        XCTAssertEqual(outcome.settings, 4)
        XCTAssertEqual(LedgerOwnAccounts.names(store), ["비상금 통장"])
        XCTAssertTrue(LedgerMessageRules.rules(store).isEmpty)
        XCTAssertTrue(PaymentInbox.items(store).isEmpty)
        XCTAssertEqual(outcome.entries.map(\.kind), [.addOwnAccount, .removeOwnAccount, .deletePaymentRule, .deleteInboxItem])

        // 나중 것부터 되돌린다. 계좌 이름은 그 뒤 값이 그대로일 때만 돌아간다.
        let preferences = AssistantPreferenceStore.test(store)
        for entry in outcome.entries.reversed().prefix(3) {
            let undone = await model.undoAssistantEntry(entry, preferences: preferences)
            XCTAssertTrue(undone, "\(entry.kind)")
        }
        XCTAssertEqual(PaymentInbox.items(store).map(\.id), [inboxID])
        XCTAssertEqual(LedgerMessageRules.rules(store), [rule])
        XCTAssertEqual(LedgerOwnAccounts.names(store), ["월급 통장", "비상금 통장"])
        LedgerOwnAccounts.set(["월급 통장", "비상금 통장", "새 통장"], defaults: store)
        let blocked = await model.undoAssistantEntry(outcome.entries[0], preferences: preferences)
        XCTAssertFalse(blocked, "사용자가 그 뒤 목록을 바꿨으면 되돌리지 않는다")
        XCTAssertEqual(LedgerOwnAccounts.names(store).count, 3)
        model.userFacingError = nil
    }

    func testOwnAccountLimitAndDisabledKinds() async throws {
        let store = defaults()
        let model = await model()
        LedgerOwnAccounts.set((1...LedgerOwnAccounts.limit).map { "통장\($0)" }, defaults: store)
        AssistantActionToggles.set(.openScreen, enabled: false, defaults: store)
        let applied = await model.applyAssistantCommands(try batch([
            command("full", "addOwnAccount", ["name": "하나 더"]),
            command("off", "openScreen", ["screen": "ledger"]),
        ]), defaults: store)
        XCTAssertEqual(applied?.results.map(\.reason), ["account_limit", "disabled"])
        XCTAssertNil(AssistantScreenRequest(defaults: store).pending)
    }

    func testBudgetAppliesAndUndoRestoresThePreviousAmount() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let set = await model.applyAssistantAction(.setBudget(month: "2026-11", amountKRW: 500_000), preferences: preferences)
        XCTAssertNil(set.reason)
        XCTAssertEqual(preferences.ledger.budget(for: "2026-11")?.amountKRW, 500_000)
        XCTAssertEqual(set.appChange?.budget, .init(month: "2026-11", before: nil, after: 500_000))
        let same = await model.applyAssistantAction(.setBudget(month: "2026-11", amountKRW: 500_000), preferences: preferences)
        XCTAssertEqual(same.reason, "no_change")
        let changed = await model.applyAssistantAction(.setBudget(month: "2026-11", amountKRW: 300_000), preferences: preferences)
        XCTAssertEqual(changed.appChange?.budget, .init(month: "2026-11", before: 500_000, after: 300_000))

        let stale = await model.undoAssistantEntry(logEntry(.setBudget, set), preferences: preferences)
        XCTAssertFalse(stale, "그 뒤 예산이 바뀌었으면 되돌리지 않는다")
        model.userFacingError = nil
        let undone = await model.undoAssistantEntry(logEntry(.setBudget, changed), preferences: preferences)
        XCTAssertTrue(undone)
        XCTAssertEqual(preferences.ledger.budget(for: "2026-11")?.amountKRW, 500_000)

        let removed = await model.applyAssistantAction(.setBudget(month: "2026-11", amountKRW: 0), preferences: preferences)
        XCTAssertNil(removed.reason)
        XCTAssertNil(preferences.ledger.budget(for: "2026-11"), "0원은 예산을 없앤다")
        let none = await model.applyAssistantAction(.setBudget(month: "2026-12", amountKRW: 0), preferences: preferences)
        XCTAssertEqual(none.reason, "no_change")
    }

    func testReviewItemsAreAddedOrDiscardedAndUndoPutsThemBack() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        preferences.review.add(LedgerEntry(occurredAt: at(11, 12, 8), amount: 3_000, title: "결제", source: .message), reason: .noMerchant, now: at(11, 12, 8, 1))
        preferences.review.add(LedgerEntry(occurredAt: at(11, 12, 9), amount: 7_000, title: "분식", source: .message), reason: .duplicate, now: at(11, 12, 9, 1))
        let first = preferences.review.items[0], second = preferences.review.items[1]

        let missing = await model.applyAssistantAction(.resolveReview(UUID(), add: true), preferences: preferences)
        XCTAssertEqual(missing.reason, "no_review")
        let dropped = await model.applyAssistantAction(.resolveReview(first.id, add: false), preferences: preferences)
        XCTAssertNil(dropped.reason)
        XCTAssertNil(dropped.ledgerEntryID)
        XCTAssertEqual(preferences.review.items.map(\.id), [second.id])
        XCTAssertTrue(preferences.ledger.entries.isEmpty, "버린 것은 가계부에 넣지 않는다")

        let added = await model.applyAssistantAction(.resolveReview(second.id, add: true), preferences: preferences)
        XCTAssertNil(added.reason)
        XCTAssertTrue(preferences.review.items.isEmpty)
        XCTAssertEqual(preferences.ledger.entries.map(\.id), [second.entry.id])
        XCTAssertEqual(added.ledgerEntryID, second.entry.id)

        let undoneAdd = await model.undoAssistantEntry(logEntry(.resolveReview, added), preferences: preferences)
        XCTAssertTrue(undoneAdd)
        XCTAssertTrue(preferences.ledger.entries.isEmpty, "넣은 기록을 지운다")
        XCTAssertEqual(preferences.review.items.map(\.id), [second.id])
        let undoneDrop = await model.undoAssistantEntry(logEntry(.resolveReview, dropped), preferences: preferences)
        XCTAssertTrue(undoneDrop)
        XCTAssertEqual(preferences.review.items, [first, second], "받은 순서 자리로 돌아온다")
        XCTAssertEqual(LedgerReviewStore(defaults: store).items, [first, second], "기기에 남는다")
    }

    /// ASK1112A01: 질문 명령을 서버와 같은 규칙으로 읽는다.
    func testAskUserParsesQuestionWithTwoToFourDistinctOptions() throws {
        let parsed = try batch([
            command("q1", "askUser", ["question": " 어제 14시에 머문 곳은 어디였나요? ", "options": ["회사", " 카페 "], "multiSelect": true]),
            command("q2", "askUser", ["question": "Which?", "options": ["A", "B", "C", "D"]]),
            command("one", "askUser", ["question": "Q?", "options": ["A"]]),
            command("five", "askUser", ["question": "Q?", "options": ["A", "B", "C", "D", "E"]]),
            command("same", "askUser", ["question": "Q?", "options": ["A", "A "]]),
            command("blank", "askUser", ["question": "Q?", "options": ["A", " "]]),
            command("noQuestion", "askUser", ["options": ["A", "B"]]),
            command("long", "askUser", ["question": String(repeating: "가", count: 201), "options": ["A", "B"]]),
            command("longOption", "askUser", ["question": "Q?", "options": ["A", String(repeating: "나", count: 61)]]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["one", "five", "same", "blank", "noQuestion", "long", "longOption"])
        guard case let .askUser(first) = parsed.commands[0].action, case let .askUser(second) = parsed.commands[1].action else { return XCTFail("askUser") }
        XCTAssertEqual([first.id, first.question], ["q1", "어제 14시에 머문 곳은 어디였나요?"], "질문 id는 명령 id다")
        XCTAssertEqual(first.options, ["회사", "카페"])
        XCTAssertTrue(first.multiSelect)
        XCTAssertFalse(second.multiSelect)
        XCTAssertEqual(parsed.commands.map(\.action.kind), [.askUser, .askUser])
        XCTAssertEqual(parsed.commands[0].action.existingChangeCount, 0)
    }

    /// ASK1112A01: 질문은 자료를 바꾸지 않고 기기에 남으며, 답·건너뛰기·되돌리기와 올릴 본문.
    func testAskUserStoresTheQuestionAnswersUploadAndUndoWithdrawsOnlyUnanswered() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        func question(_ id: String, multi: Bool = false) throws -> AssistantQuestion {
            try XCTUnwrap(AssistantQuestion.make(id: id, question: "어디였나요?", options: ["회사", "카페", "집"], multiSelect: multi, now: at(11, 12, 9)))
        }
        let asked = await model.applyAssistantAction(.askUser(try question("q1")), preferences: preferences)
        XCTAssertNil(asked.reason)
        XCTAssertEqual(asked.appChange?.questionID, "q1")
        XCTAssertEqual(preferences.questions.waiting.map(\.id), ["q1"])
        XCTAssertEqual(preferences.questions.announced?.id, "q1", "알림으로 보인다")
        XCTAssertTrue(preferences.questions.needsUpload, "기다리는 질문도 AI가 볼 수 있게 올린다")
        XCTAssertTrue(model.snapshot.plans.isEmpty && model.snapshot.memos.isEmpty, "자료는 바꾸지 않는다")
        let again = await model.applyAssistantAction(.askUser(try question("q1")), preferences: preferences)
        XCTAssertEqual(again.reason, "duplicate")

        let questions = preferences.questions
        XCTAssertFalse(questions.answer("q1", choices: ["없는 보기"], text: "  "), "보기에 없는 것과 빈 글은 답이 아니다")
        XCTAssertTrue(questions.answer("q1", choices: ["카페", "회사"], text: " 스타벅스 2층 ", now: at(11, 12, 10)))
        XCTAssertEqual(questions.items[0].choices, ["회사"], "하나만 고르는 질문은 보기 순서의 첫 것만")
        XCTAssertEqual(questions.items[0].text, "스타벅스 2층")
        XCTAssertNil(questions.announced)
        XCTAssertFalse(questions.answer("q1", choices: ["집"], text: nil), "한 번만 답한다")

        _ = await model.applyAssistantAction(.askUser(try question("q2", multi: true)), preferences: preferences)
        _ = await model.applyAssistantAction(.askUser(try question("q3")), preferences: preferences)
        XCTAssertTrue(questions.answer("q2", choices: ["집", "회사"], text: nil, now: at(11, 12, 11)))
        XCTAssertEqual(questions.items[1].choices, ["회사", "집"])
        let reloaded = AssistantQuestionStore(defaults: store)
        XCTAssertEqual(reloaded.items, questions.items, "앱이 다시 켜져도 남는다")

        let body = try XCTUnwrap(questions.uploadBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "bokki-answers")
        let answers = try XCTUnwrap(json["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.map { $0["status"] as? String }, ["answered", "answered", "waiting"])
        XCTAssertEqual(answers[0]["choices"] as? [String], ["회사"])
        XCTAssertEqual(answers[0]["text"] as? String, "스타벅스 2층")
        XCTAssertNil(answers[2]["choices"])
        XCTAssertNotNil(answers[0]["answeredAt"])

        let kept = await model.undoAssistantEntry(logEntry(.askUser, asked), preferences: preferences)
        XCTAssertTrue(kept)
        XCTAssertEqual(questions.items.count, 3, "답한 질문은 되돌려도 남는다")
        let third = AssistantEditResult(after: "어디였나요?", appChange: AssistantAppChange(questionID: "q3"))
        _ = await model.undoAssistantEntry(logEntry(.askUser, third), preferences: preferences)
        XCTAssertEqual(questions.items.map(\.id), ["q1", "q2"], "답하지 않은 질문은 거둔다")

        questions.skip("q2")
        XCTAssertEqual(questions.items[1].status, .answered, "답한 것은 건너뛰기로 바뀌지 않는다")
        questions.clearFinished()
        XCTAssertNil(questions.uploadBody(), "비면 서버 목록을 지운다")
        let old = AssistantQuestionStore(defaults: store)
        var stale = try question("old")
        stale.askedAt = at(11, 1, 9)
        old.add(stale, now: at(11, 1, 9))
        XCTAssertEqual(old.items.map(\.id), ["old"])
        old.prune(now: at(11, 12, 9))
        XCTAssertTrue(old.items.isEmpty, "7일 지난 질문은 버린다")
    }

    /// ASK1112A01: 꺼 두면 받지 않고, 안내문에 질문 명령과 답 읽는 길이 있다.
    func testAskUserCanBeTurnedOffAndIsInTheSetupText() async throws {
        let store = defaults()
        let model = await model()
        AssistantActionToggles.set(.askUser, enabled: false, defaults: store)
        let outcome = await model.applyAssistantCommands(try batch([command("off", "askUser", ["question": "Q?", "options": ["A", "B"]])]), defaults: store)
        XCTAssertEqual(outcome?.results.map(\.reason), ["disabled"])
        XCTAssertTrue(AssistantQuestionStore(defaults: store).items.isEmpty)
        AssistantActionToggles.set(.askUser, enabled: true, defaults: store)
        let applied = await model.applyAssistantCommands(try batch([command("on", "askUser", ["question": "Q?", "options": ["A", "B"]])]), defaults: store)
        XCTAssertEqual(applied?.questions, 1)
        XCTAssertEqual(applied?.notice(.korean)?.contains("질문 1개"), true)
        let write = TripRelay.assistantSetupText(host: "relay.example.com", key: "K", scope: .write)
        XCTAssertTrue(write.contains("\"askUser\",\"question\""))
        XCTAssertTrue(write.contains("GET /answers"))
        XCTAssertFalse(TripRelay.assistantSetupText(host: "relay.example.com", key: "K", scope: .read).contains("askUser"))
    }

    /// ACA1112A01: 장소·분류 명령을 서버와 같은 규칙으로 읽는다.
    func testPlaceAndCategoryCommandsParseWithTheServerRules() throws {
        let parsed = try batch([
            command("p1", "addPlace", ["name": " 체육관 ", "latitude": 37.5, "longitude": 127.0, "radius": 150, "autoRecord": false]),
            command("p2", "addPlace", ["name": "도서관"]),
            command("p3", "updatePlace", ["placeId": id, "radius": 30]),
            command("p4", "deletePlace", ["placeId": id]),
            command("c1", "addCategory", ["name": "독서", "color": "#3366ff", "icon": "book"]),
            command("c2", "updateCategory", ["categoryId": "study", "hidden": true]),
            command("half", "addPlace", ["name": "X", "latitude": 37.5]),
            command("small", "addPlace", ["name": "X", "radius": 29]),
            command("big", "updatePlace", ["placeId": id, "radius": 501]),
            command("nothing", "updatePlace", ["placeId": id]),
            command("badId", "deletePlace", ["placeId": "home"]),
            command("noColor", "addCategory", ["name": "X"]),
            command("badColor", "addCategory", ["name": "X", "color": "blue"]),
            command("badIcon", "addCategory", ["name": "X", "color": "#3366FF", "icon": "rocket"]),
            command("empty", "updateCategory", ["categoryId": "study"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["half", "small", "big", "nothing", "badId", "noColor", "badColor", "badIcon", "empty"])
        let uuid = try XCTUnwrap(UUID(uuidString: id))
        XCTAssertEqual(parsed.commands.map(\.action), [
            .addPlace(name: "체육관", coordinate: AssistantCoordinate(latitude: 37.5, longitude: 127.0), radius: 150, autoRecord: false),
            .addPlace(name: "도서관", coordinate: nil, radius: nil, autoRecord: nil),
            .updatePlace(placeID: uuid, name: nil, coordinate: nil, radius: 30, autoRecord: nil),
            .deletePlace(uuid),
            .addCategory(name: "독서", color: "#3366FF", icon: .book),
            .updateCategory(categoryID: "study", name: nil, color: nil, icon: nil, hidden: true),
        ])
        XCTAssertEqual(parsed.commands.map(\.action.existingChangeCount), [0, 0, 1, 1, 0, 1])
    }

    /// ACA1112A01: 장소를 더하고 고치고 지우며, 「AI가 한 일」에서 되돌린다. 그 뒤 목록이 바뀌었으면 되돌리지 않는다.
    func testPlacesAreAddedEditedDeletedAndUndone() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let start = model.snapshot.settings.frequentPlaces
        let addedOutcome = await model.applyAssistantCommands(try batch([
            command("p1", "addPlace", ["name": "체육관", "latitude": 37.5, "longitude": 127.0, "radius": 150, "autoRecord": false]),
            command("dup", "addPlace", ["name": "체육관"]),
        ]), defaults: store)
        let added = try XCTUnwrap(addedOutcome)
        XCTAssertEqual(added.results.map(\.reason), [nil, "duplicate"])
        XCTAssertEqual(added.settings, 1)
        let gym = try XCTUnwrap(model.snapshot.settings.frequentPlaces.first { $0.name == "체육관" })
        XCTAssertEqual([gym.radiusMeters, gym.point?.latitude, gym.point?.longitude], [150, 37.5, 127.0])
        XCTAssertFalse(gym.isAutomaticRecordingEnabled)
        XCTAssertEqual(gym.kind, .custom)

        let editedOutcome = await model.applyAssistantCommands(try batch([
            command("p2", "updatePlace", ["placeId": gym.id.uuidString, "name": "헬스장", "radius": 80, "autoRecord": true]),
            command("same", "updatePlace", ["placeId": gym.id.uuidString, "radius": 80]),
            command("missing", "updatePlace", ["placeId": id, "radius": 80]),
        ]), defaults: store)
        let edited = try XCTUnwrap(editedOutcome)
        XCTAssertEqual(edited.results.map(\.reason), [nil, "no_change", "no_place"])
        let renamed = try XCTUnwrap(model.snapshot.settings.frequentPlaces.first { $0.id == gym.id })
        XCTAssertEqual(renamed.name, "헬스장")
        XCTAssertEqual(renamed.radiusMeters, 80)
        XCTAssertTrue(renamed.isAutomaticRecordingEnabled)
        XCTAssertEqual(edited.entries.first?.before, "체육관 · 150m")
        XCTAssertEqual(edited.entries.first?.after, "헬스장 · 80m")

        let undoneEdit = await model.undoAssistantEntry(try XCTUnwrap(edited.entries.first), preferences: preferences)
        XCTAssertTrue(undoneEdit)
        XCTAssertEqual(model.snapshot.settings.frequentPlaces.first { $0.id == gym.id }?.name, "체육관")

        let deletedOutcome = await model.applyAssistantCommands(try batch([command("p3", "deletePlace", ["placeId": gym.id.uuidString])]), defaults: store)
        let deleted = try XCTUnwrap(deletedOutcome)
        XCTAssertEqual(deleted.results.map(\.reason), [nil])
        XCTAssertNil(model.snapshot.settings.frequentPlaces.first { $0.id == gym.id })
        let undoneDelete = await model.undoAssistantEntry(try XCTUnwrap(deleted.entries.first), preferences: preferences)
        XCTAssertTrue(undoneDelete)
        XCTAssertNotNil(model.snapshot.settings.frequentPlaces.first { $0.id == gym.id })

        model.renameFrequentPlace(gym.id, name: "내가 고친 이름")
        let blocked = await model.undoAssistantEntry(try XCTUnwrap(added.entries.first), preferences: preferences)
        XCTAssertFalse(blocked, "그 뒤 사용자가 고쳤으면 되돌리지 않는다")
        model.renameFrequentPlace(gym.id, name: "체육관")
        _ = start
    }

    /// ACA1112A01: 분류를 더하고 고치고 숨기며 되돌린다. 화면 오류 알림은 띄우지 않는다.
    func testCategoriesAreAddedEditedHiddenAndUndone() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let addedOutcome = await model.applyAssistantCommands(try batch([
            command("c1", "addCategory", ["name": "독서", "color": "#3366FF", "icon": "book"]),
            command("dup", "addCategory", ["name": "독서", "color": "#112233"]),
        ]), defaults: store)
        let added = try XCTUnwrap(addedOutcome)
        XCTAssertEqual(added.results.map(\.applied), [true, false])
        XCTAssertNil(model.userFacingError, "AI 명령 실패는 화면 오류로 띄우지 않는다")
        let reading = try XCTUnwrap(model.snapshot.categories.first { $0.name == "독서" })
        XCTAssertEqual([reading.lightHex.uppercased(), reading.icon.rawValue], ["#3366FF", "book"])
        XCTAssertFalse(reading.isBuiltIn)

        let editedOutcome = await model.applyAssistantCommands(try batch([
            command("c2", "updateCategory", ["categoryId": reading.id, "name": "책 읽기", "hidden": true]),
            command("missing", "updateCategory", ["categoryId": "nope", "hidden": true]),
            command("unconfirmed", "updateCategory", ["categoryId": "unconfirmed", "hidden": true]),
        ]), defaults: store)
        let edited = try XCTUnwrap(editedOutcome)
        XCTAssertEqual(edited.results.map(\.reason), [nil, "unknown_category", "unknown_category"])
        let hidden = try XCTUnwrap(model.snapshot.categories.first { $0.id == reading.id })
        XCTAssertEqual(hidden.name, "책 읽기")
        XCTAssertTrue(hidden.isHidden)

        let undone = await model.undoAssistantEntry(try XCTUnwrap(edited.entries.first), preferences: preferences)
        XCTAssertTrue(undone)
        XCTAssertEqual(model.snapshot.categories.first { $0.id == reading.id }, reading)
        let removed = await model.undoAssistantEntry(try XCTUnwrap(added.entries.first), preferences: preferences)
        XCTAssertTrue(removed)
        XCTAssertNil(model.snapshot.categories.first { $0.id == reading.id })
    }

    /// ACA1112A01: 앱 상태에 분류는 늘, 장소는 「머문 곳 이름」 공유 수준에서만. 좌표는 없다.
    func testAppStateCarriesCategoriesAndPlacesOnlyAtThePlaceNameLevel() throws {
        var value = try input()
        var office = FrequentPlace(kind: .company, name: "마곡 회사")
        office.setMapLocation(GeoPoint(latitude: 37.56, longitude: 126.83, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5))
        value.places = [office, FrequentPlace(kind: .custom, name: "체육관")]
        value.categories = [
            try CategoryCatalog.makeCustom(name: "독서", icon: .book, lightHex: "#3366FF", existing: []),
        ]
        let summary = AssistantAppStateSync.make(value)
        XCTAssertNil(summary.places, "하루 요약 수준에서는 장소 이름을 올리지 않는다")
        XCTAssertEqual(summary.categories?.map(\.name), ["독서"])
        XCTAssertEqual(summary.categories?.first?.custom, true)
        value.shareLevel = .visits
        let detailed = AssistantAppStateSync.make(value)
        XCTAssertEqual(detailed.places?.map(\.name), ["마곡 회사", "체육관"])
        XCTAssertEqual(detailed.places?.map(\.located), [true, false])
        XCTAssertEqual(detailed.places?.first?.kind, "company")
        let json = String(decoding: try XCTUnwrap(AssistantAppStateSync.body(detailed)), as: UTF8.self)
        XCTAssertFalse(json.contains("37.56") || json.contains("126.83") || json.contains("latitude"), "좌표는 내보내지 않는다")
    }

    /// ACB1112A01: 여행·설정 명령을 서버와 같은 규칙으로 읽는다.
    func testTripAndSettingCommandsParseWithTheServerRules() throws {
        let parsed = try batch([
            command("t1", "addTrip", ["title": " 오사카 ", "start": "2026-12-01", "end": "2026-12-04", "countryCode": "JP", "currency": "JPY"]),
            command("t2", "addTrip", ["title": "당일치기", "start": "2026-12-01"]),
            command("t3", "addTrip", ["title": "언젠가", "wishDays": 7]),
            command("t4", "updateTrip", ["tripId": "trip-1", "start": "2026-12-02"]),
            command("t5", "deleteTrip", ["tripId": "trip-1"]),
            command("s1", "setSetting", ["setting": "tollVehicle", "value": "electric"]),
            command("s2", "setSetting", ["setting": "annualPay", "value": 50_000_000]),
            command("s3", "setSetting", ["setting": "weeklyHolidayPay", "value": true]),
            command("noDates", "addTrip", ["title": "X"]),
            command("backwards", "addTrip", ["title": "X", "start": "2026-12-04", "end": "2026-12-01"]),
            command("both", "addTrip", ["title": "X", "wishDays": 3, "start": "2026-12-01"]),
            command("lower", "addTrip", ["title": "X", "start": "2026-12-01", "countryCode": "jp"]),
            command("empty", "updateTrip", ["tripId": "trip-1"]),
            command("unknown", "setSetting", ["setting": "backupPin", "value": "123456"]),
            command("truck", "setSetting", ["setting": "tollVehicle", "value": "truck"]),
            command("negative", "setSetting", ["setting": "annualPay", "value": -1]),
            command("wrongType", "setSetting", ["setting": "payIsNet", "value": "true"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["noDates", "backwards", "both", "lower", "empty", "unknown", "truck", "negative", "wrongType"])
        XCTAssertEqual(parsed.commands.map(\.action.kind), [.addTrip, .addTrip, .addTrip, .updateTrip, .deleteTrip, .setSetting, .setSetting, .setSetting])
        guard case let .addTrip(osaka) = parsed.commands[0].action, case let .addTrip(dayTrip) = parsed.commands[1].action,
              case let .addTrip(wish) = parsed.commands[2].action else { return XCTFail("addTrip") }
        XCTAssertEqual([osaka.title, osaka.startDay, osaka.endDay, osaka.countryCode, osaka.currencyCode], ["오사카", "2026-12-01", "2026-12-04", "JP", "JPY"])
        XCTAssertTrue(osaka.id.hasPrefix("trip-"))
        XCTAssertEqual([dayTrip.startDay, dayTrip.endDay], ["2026-12-01", "2026-12-01"])
        XCTAssertTrue(wish.isWish)
        XCTAssertEqual(wish.wishDays, 7)
        XCTAssertEqual(Array(parsed.commands.map(\.action).suffix(3)), [
            .setSetting(.tollVehicle, value: "electric"), .setSetting(.annualPay, value: "50000000.0"), .setSetting(.weeklyHolidayPay, value: "true"),
        ])
    }

    /// ACB1112A01: 여행을 만들고 날짜를 옮기고 지우며 되돌린다.
    func testTripsAreCreatedMovedDeletedAndUndone() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let addedOutcome = await model.applyAssistantCommands(try batch([
            command("t1", "addTrip", ["title": "오사카", "start": "2026-12-01", "end": "2026-12-04", "countryCode": "JP"]),
            command("t2", "addTrip", ["title": "언젠가 아이슬란드", "wishDays": 7]),
        ]), defaults: store)
        let added = try XCTUnwrap(addedOutcome)
        XCTAssertEqual(added.results.map(\.reason), [nil, nil])
        XCTAssertEqual(added.schedules, 2)
        let trips = try XCTUnwrap(model.snapshot.settings.travelTrips)
        let osaka = try XCTUnwrap(trips.first { $0.title == "오사카" }), wish = try XCTUnwrap(trips.first { $0.isWish })
        XCTAssertEqual(osaka.currencyCode, "JPY", "나라를 주면 화면처럼 여행지 통화를 잡는다")
        XCTAssertNotNil(osaka.latitude)

        let movedOutcome = await model.applyAssistantCommands(try batch([
            command("m1", "updateTrip", ["tripId": osaka.id, "start": "2026-12-10"]),
            command("m2", "updateTrip", ["tripId": wish.id, "start": "2027-06-01"]),
            command("same", "updateTrip", ["tripId": osaka.id, "title": "오사카"]),
            command("missing", "updateTrip", ["tripId": "trip-nope", "title": "X"]),
        ]), defaults: store)
        let moved = try XCTUnwrap(movedOutcome)
        XCTAssertEqual(moved.results.map(\.reason), [nil, nil, "no_change", "no_trip"])
        let shifted = try XCTUnwrap(model.snapshot.settings.travelTrips?.first { $0.id == osaka.id })
        XCTAssertEqual([shifted.startDay, shifted.endDay], ["2026-12-10", "2026-12-13"], "첫날만 옮기면 길이를 지킨다")
        let scheduled = try XCTUnwrap(model.snapshot.settings.travelTrips?.first { $0.id == wish.id })
        XCTAssertEqual([scheduled.startDay, scheduled.endDay], ["2027-06-01", "2027-06-07"], "날짜 없는 여행은 정해 둔 날 수만큼")
        XCTAssertNil(scheduled.wishDays)

        let undoneWish = await model.undoAssistantEntry(try XCTUnwrap(moved.entries.last), preferences: preferences)
        XCTAssertTrue(undoneWish)
        XCTAssertEqual(model.snapshot.settings.travelTrips?.first { $0.id == wish.id }?.isWish, true)

        let deletedOutcome = await model.applyAssistantCommands(try batch([command("d1", "deleteTrip", ["tripId": osaka.id])]), defaults: store)
        let deleted = try XCTUnwrap(deletedOutcome)
        XCTAssertEqual(deleted.results.map(\.reason), [nil])
        XCTAssertNil(model.snapshot.settings.travelTrips?.first { $0.id == osaka.id })
        let restored = await model.undoAssistantEntry(try XCTUnwrap(deleted.entries.first), preferences: preferences)
        XCTAssertTrue(restored)
        XCTAssertEqual(model.snapshot.settings.travelTrips?.first { $0.id == osaka.id }, shifted)
    }

    /// ACB1112A01·PAY1112A01: 설정은 정해진 이름·형만 바꾸고 되돌리며, 급여 금액도 앱 상태에 올린다.
    func testSettingsChangeUndoAndPayAmountsAreReadable() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let outcome = await model.applyAssistantCommands(try batch([
            command("s1", "setSetting", ["setting": "tollVehicle", "value": "electric"]),
            command("s2", "setSetting", ["setting": "annualPay", "value": 50_000_000]),
            command("s3", "setSetting", ["setting": "salaryMode", "value": "hourly"]),
            command("again", "setSetting", ["setting": "tollVehicle", "value": "electric"]),
        ]), defaults: store)
        let changed = try XCTUnwrap(outcome)
        XCTAssertEqual(changed.results.map(\.reason), [nil, nil, nil, "no_change"])
        XCTAssertEqual(LedgerTollDiscount.vehicle(store), .electric)
        XCTAssertEqual(store.double(forKey: MapHomeSalaryPolicy.annualKey), 50_000_000)
        XCTAssertTrue(store.bool(forKey: MapHomeSalaryPolicy.isHourlyKey))
        XCTAssertEqual(changed.entries.first?.before, "통행료 차종: 정하지 않음")

        let undone = await model.undoAssistantEntry(try XCTUnwrap(changed.entries.first), preferences: preferences)
        XCTAssertTrue(undone)
        XCTAssertNil(store.object(forKey: LedgerTollDiscount.vehicleKey), "정하기 전으로 돌아간다")

        var value = try input()
        value.tollVehicle = "compact"
        value.salaryMode = "hourly"
        value.trips = [TravelTrip(id: "trip-1", title: "오사카", startDay: "2026-12-01", endDay: "2026-12-04", countryCode: "JP", latitude: 34.69, longitude: 135.5, currencyCode: "JPY")]
        value.settingValues = ["annualPay": "50000000.0", "salaryMode": "hourly"]
        let state = AssistantAppStateSync.make(value)
        XCTAssertEqual([state.settings.tollVehicle, state.settings.salaryMode], ["compact", "hourly"])
        XCTAssertEqual(state.settings.values?["annualPay"], "50000000.0", "급여 금액도 AI가 읽는다(PAY1112A01)")
        XCTAssertEqual(state.trips?.map(\.id), ["trip-1"])
        let json = String(decoding: try XCTUnwrap(AssistantAppStateSync.body(state)), as: UTF8.self)
        XCTAssertTrue(json.contains("annualPay"))
        XCTAssertFalse(json.contains("34.69") || json.contains("latitude"), "좌표는 올리지 않는다")
    }

    /// ACC1112A01: 앱 자료 쪽 설정은 화면의 설정 함수로 바꾸고 되돌리며, 알림은 끄기만 받는다.
    func testAppSettingsChangeThroughTheModelAndUndo() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let parsed = try batch([
            command("s1", "setSetting", ["setting": "reduceMotion", "value": true]),
            command("s2", "setSetting", ["setting": "gpsIntervalSeconds", "value": 600]),
            command("s3", "setSetting", ["setting": "cat", "value": "mackerel"]),
            command("s4", "setSetting", ["setting": "weatherSidebar", "value": !model.snapshot.settings.weatherSidebarVisible]),
            command("on", "setSetting", ["setting": "notifications", "value": true]),
            command("odd", "setSetting", ["setting": "gpsIntervalSeconds", "value": 45]),
            command("far", "setSetting", ["setting": "gpsIntervalSeconds", "value": 3_600]),
            command("tiger", "setSetting", ["setting": "cat", "value": "tiger"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["on", "odd", "far", "tiger"])
        let gpsBefore = model.snapshot.settings.gpsLoggingPreferences.intervalSeconds
        let sidebarBefore = model.snapshot.settings.weatherSidebarVisible
        let outcome = await model.applyAssistantCommands(parsed, defaults: store)
        let changed = try XCTUnwrap(outcome)
        XCTAssertEqual(changed.results.filter(\.applied).map(\.id), ["s1", "s2", "s3", "s4"].filter { $0 != "s2" || gpsBefore != 600 })
        XCTAssertTrue(model.snapshot.settings.reduceMotion)
        XCTAssertEqual(model.snapshot.settings.gpsLoggingPreferences.intervalSeconds, 600)
        XCTAssertEqual(model.snapshot.settings.catStyle, .mackerel)
        XCTAssertEqual(model.snapshot.settings.weatherSidebarVisible, !sidebarBefore)
        XCTAssertNil(store.object(forKey: AssistantSetting.reduceMotion.key), "앱 자료 쪽 설정은 기기 설정에 쓰지 않는다")

        let entry = try XCTUnwrap(changed.entries.first { $0.commandID == "s1" })
        let undone = await model.undoAssistantEntry(entry, preferences: preferences)
        XCTAssertTrue(undone)
        for _ in 0..<50 where model.snapshot.settings.reduceMotion { await Task.yield() }
        XCTAssertFalse(model.snapshot.settings.reduceMotion)

        let state = AssistantAppStateSync.make(await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(11, 12, 10), calendar: calendar))
        XCTAssertEqual(state.settings.values?["gpsIntervalSeconds"], "600")
        XCTAssertEqual(state.settings.values?["cat"], "mackerel")
        XCTAssertNil(state.settings.values?["annualPay"], "정하지 않은 금액은 칸이 없다")
        store.set(42_000_000.0, forKey: MapHomeSalaryPolicy.annualKey)
        let withPay = AssistantAppStateSync.make(await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(11, 12, 10), calendar: calendar))
        XCTAssertEqual(withPay.settings.values?["annualPay"], "42000000.0", "정해 둔 연봉은 읽힌다(PAY1112A01)")

        // PAY1112A02: 연봉 카운터의 「AI 연동」을 끄면 급여 설정은 올리지도 바꾸지도 않는다. 다른 설정은 그대로다.
        XCTAssertTrue(MapHomeSalaryPolicy.isAILinked(store), "기본은 켬")
        store.set(false, forKey: MapHomeSalaryPolicy.aiLinkKey)
        store.set(true, forKey: MapHomeSalaryPolicy.isHourlyKey)
        let unlinked = AssistantAppStateSync.make(await AssistantAppStateSync.input(model: model, preferences: preferences, now: at(11, 12, 10), calendar: calendar))
        XCTAssertNil(unlinked.settings.values?["annualPay"])
        XCTAssertNil(unlinked.settings.values?["salaryMode"])
        XCTAssertNil(unlinked.settings.salaryMode)
        XCTAssertEqual(unlinked.settings.values?["gpsIntervalSeconds"], "600")
        let refusedOutcome = await model.applyAssistantCommands(try batch([
            command("pay", "setSetting", ["setting": "annualPay", "value": 1]),
            command("tax", "setSetting", ["setting": "hourlyTax", "value": "none"]),
            command("car", "setSetting", ["setting": "tollVehicle", "value": "compact"]),
        ]), defaults: store)
        let refused = try XCTUnwrap(refusedOutcome)
        XCTAssertEqual(refused.results.map(\.reason), ["salary_link_off", "salary_link_off", nil])
        XCTAssertEqual(store.double(forKey: MapHomeSalaryPolicy.annualKey), 42_000_000, "금액은 그대로다")
    }

    /// ACD1112A01: 승인 요청은 정해진 종류와 값만 읽고, 승인하기 전에는 아무것도 바꾸지 않는다.
    func testApprovalRequestsWaitForTheUserAndApplyOnlyWhenApproved() async throws {
        let store = defaults()
        let model = await model()
        let parsed = try batch([
            command("a1", "requestApproval", ["request": "shareLevel", "value": "visits"]),
            command("a2", "requestApproval", ["request": "retentionDays", "value": 1]),
            command("a3", "requestApproval", ["request": "eraseAllData"]),
            command("a4", "requestApproval", ["request": "backup"]),
            command("noValue", "requestApproval", ["request": "shareLevel"]),
            command("badLevel", "requestApproval", ["request": "shareLevel", "value": "everything"]),
            command("badDays", "requestApproval", ["request": "retentionDays", "value": 365]),
            command("extra", "requestApproval", ["request": "eraseAllData", "value": true]),
            command("unknown", "requestApproval", ["request": "sendMoney"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["noValue", "badLevel", "badDays", "extra", "unknown"])
        XCTAssertEqual(parsed.commands.map(\.action.kind), [.requestApproval, .requestApproval, .requestApproval, .requestApproval])

        store.set(AssistantShareLevel.summary.rawValue, forKey: AssistantShareLevel.defaultsKey)
        store.set(AssistantRetention.week.rawValue, forKey: AssistantRetention.defaultsKey)
        let outcome = await model.applyAssistantCommands(parsed, defaults: store)
        let asked = try XCTUnwrap(outcome)
        XCTAssertEqual(asked.questions, 4)
        let questions = AssistantQuestionStore(defaults: store)
        XCTAssertEqual(questions.waiting.map(\.id), ["a1", "a2", "a3", "a4"])
        XCTAssertEqual(AssistantShareLevel.current(store), .summary, "승인 전에는 바뀌지 않는다")
        XCTAssertEqual(asked.entries.first?.after, "AI 공유 수준을 「머문 곳 이름과 시각」(으)로 바꿀까요?")

        let screens = AssistantScreenRequest(defaults: store)
        let share = try XCTUnwrap(questions.waiting[0].approval), retention = try XCTUnwrap(questions.waiting[1].approval)
        let erase = try XCTUnwrap(questions.waiting[2].approval)
        XCTAssertTrue(questions.answer("a1", choices: [AssistantApproval.approved], text: nil))
        await share.perform(model: model, defaults: store, screens: screens)
        XCTAssertEqual(AssistantShareLevel.current(store), .visits)
        XCTAssertFalse(store.bool(forKey: AssistantActivitySync.pendingClearKey), "더 보내는 쪽은 서버 기록을 지우지 않는다")
        await retention.perform(model: model, defaults: store, screens: screens)
        XCTAssertEqual(AssistantRetention.current(store), .oneDay)
        XCTAssertTrue(store.bool(forKey: AssistantActivitySync.pendingClearKey), "기간을 줄이면 서버 기록을 지운다")
        XCTAssertNil(screens.pending)
        await erase.perform(model: model, defaults: store, screens: screens)
        XCTAssertEqual(screens.pending, .settings, "삭제는 화면만 연다")

        XCTAssertTrue(questions.answer("a4", choices: [AssistantApproval.declined], text: nil))
        let body = try XCTUnwrap(questions.uploadBody())
        let answers = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.map { $0["status"] as? String }, ["answered", "waiting", "waiting", "answered"])
        XCTAssertEqual(answers[0]["choices"] as? [String], ["approved"])
        XCTAssertEqual(answers[3]["choices"] as? [String], ["declined"])
        XCTAssertEqual(answers[0]["question"] as? String, "Approval request: shareLevel = visits")
    }

    /// HND1112A01: 「확인할 것」 세 가지를 끝내는 명령 — 읽기, 내 차·일정 제목의 적용과 되돌리기, 장소 제안의 등록·거절.
    func testPromptCommandsParseApplyAndUndo() async throws {
        let detail = try XCTUnwrap(CalendarTitleClassification.selectableCategories.flatMap(\.details).first?.id)
        let parsed = try batch([
            command("car", "setCarAudio", ["name": "Audi", "isMyCar": true]),
            command("title", "setCalendarTitleDetail", ["title": "주간 회의", "detailId": detail]),
            command("none", "setCalendarTitleDetail", ["title": "생일", "detailId": "none"]),
            command("place", "resolvePlaceSuggestion", ["decision": "register", "name": "단골 카페", "kind": "restaurant"]),
            command("drop", "resolvePlaceSuggestion", ["decision": "dismiss"]),
            command("badDetail", "setCalendarTitleDetail", ["title": "X", "detailId": "movement.subway"]),
            command("noFlag", "setCarAudio", ["name": "Audi"]),
            command("dismissName", "resolvePlaceSuggestion", ["decision": "dismiss", "name": "X"]),
            command("badKind", "resolvePlaceSuggestion", ["decision": "register", "kind": "palace"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["badDetail", "noFlag", "dismissName", "badKind"])
        XCTAssertEqual(parsed.commands.map(\.action), [
            .setCarAudio(name: "Audi", isMyCar: true), .setCalendarTitleDetail(title: "주간 회의", detailID: detail),
            .setCalendarTitleDetail(title: "생일", detailID: nil), .resolvePlaceSuggestion(register: true, name: "단골 카페", kind: .restaurant),
            .resolvePlaceSuggestion(register: false, name: nil, kind: nil),
        ])

        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        await model.updateCarAudioNames(registered: [], recent: ["Audi"])
        let firstOutcome = await model.applyAssistantCommands(try batch([
            command("car", "setCarAudio", ["name": "Audi", "isMyCar": true]),
            command("unknown", "setCarAudio", ["name": "남의 차", "isMyCar": true]),
            command("title", "setCalendarTitleDetail", ["title": "주간 회의", "detailId": detail]),
            command("same", "setCalendarTitleDetail", ["title": " 주간 회의 ", "detailId": detail]),
        ]), defaults: store)
        let first = try XCTUnwrap(firstOutcome)
        XCTAssertEqual(first.results.map(\.reason), [nil, "no_device", nil, "no_change"])
        // 시험용 앱은 기기의 실제 체류로 제안을 만들 수 있어, 제안이 없는 상태를 직접 만든다.
        model.frequentPlaceSuggestion = nil
        let nothingOutcome = await model.applyAssistantCommands(try batch([command("nothing", "resolvePlaceSuggestion", ["decision": "dismiss"])]), defaults: store)
        XCTAssertEqual(nothingOutcome?.results.map(\.reason), ["no_suggestion"])
        XCTAssertEqual(model.settings.registeredCarAudioNames, ["Audi"])
        XCTAssertTrue(model.settings.recentCarAudioNames.isEmpty)
        XCTAssertEqual(model.snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key("주간 회의")]?.detailID, detail)

        let undoneCar = await model.undoAssistantEntry(try XCTUnwrap(first.entries.first { $0.commandID == "car" }), preferences: preferences)
        XCTAssertTrue(undoneCar)
        XCTAssertEqual([model.settings.registeredCarAudioNames, model.settings.recentCarAudioNames], [[], ["Audi"]], "다시 물을 수 있게 돌아간다")
        let undoneTitle = await model.undoAssistantEntry(try XCTUnwrap(first.entries.first { $0.commandID == "title" }), preferences: preferences)
        XCTAssertTrue(undoneTitle)
        XCTAssertNil(model.snapshot.settings.calendarTitleDetails[CalendarTitleClassification.key("주간 회의")], "정하기 전으로 돌아간다")

        let point = GeoPoint(latitude: 37.5, longitude: 127.0, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5)
        model.frequentPlaceSuggestion = FrequentPlaceSuggestion(
            id: "s1", point: point, suggestedName: "서울특별시 강남구 테헤란로 1", visitCount: 4,
            firstVisitedAt: at(11, 5, 9), lastVisitedAt: at(11, 12, 9), reason: .weekly
        )
        var value = try input()
        value.shareLevel = .visits
        value.placeSuggestion = model.frequentPlaceSuggestion
        value.pendingCarAudio = ["Audi"]
        let state = AssistantAppStateSync.make(value)
        XCTAssertEqual(state.placeSuggestion, .init(id: "s1", name: nil, visits: 4), "주소처럼 보이는 이름과 좌표는 올리지 않는다")
        XCTAssertEqual(state.carAudio, .init(registered: [], pending: ["Audi"]))
        value.shareLevel = .summary
        XCTAssertNil(AssistantAppStateSync.make(value).placeSuggestion)

        let placeOutcome = await model.applyAssistantCommands(try batch([
            command("place", "resolvePlaceSuggestion", ["decision": "register", "name": "단골 카페", "kind": "restaurant"]),
        ]), defaults: store)
        let placed = try XCTUnwrap(placeOutcome)
        XCTAssertEqual(placed.results.map(\.reason), [nil])
        let cafe = try XCTUnwrap(model.snapshot.settings.frequentPlaces.first { $0.name == "단골 카페" })
        XCTAssertEqual(cafe.kind, .restaurant)
        XCTAssertEqual(cafe.point?.latitude, 37.5)
        XCTAssertNil(model.frequentPlaceSuggestion)
        let undonePlace = await model.undoAssistantEntry(try XCTUnwrap(placed.entries.first), preferences: preferences)
        XCTAssertTrue(undonePlace)
        XCTAssertNil(model.snapshot.settings.frequentPlaces.first { $0.name == "단골 카페" })
    }

    /// TBG1112A01: 여행 예산을 정하면 장부가 없을 때는 앱 여행에서 만들고, 되돌리면 전 상태로 간다.
    func testTripBudgetCreatesTheLedgerFromThePlannedTripAndUndoes() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let parsed = try batch([
            command("b1", "setTripBudget", ["tripId": "trip-1", "budgetKRW": 800_000]),
            command("neg", "setTripBudget", ["tripId": "trip-1", "budgetKRW": -1]),
            command("noAmount", "setTripBudget", ["tripId": "trip-1"]),
        ])
        XCTAssertEqual(parsed.invalidIDs, ["neg", "noAmount"])
        XCTAssertEqual(parsed.commands.map(\.action), [.setTripBudget(tripID: "trip-1", budgetKRW: 800_000)])

        let missing = await model.applyAssistantAction(.setTripBudget(tripID: "trip-1", budgetKRW: 800_000), preferences: preferences)
        XCTAssertEqual(missing.reason, "no_trip")
        let saved = await model.saveTravelTrip(TravelTrip(id: "trip-1", title: "오사카", startDay: "2026-12-01", endDay: "2026-12-04"))
        XCTAssertTrue(saved)

        let created = await model.applyAssistantAction(.setTripBudget(tripID: "trip-1", budgetKRW: 800_000), preferences: preferences)
        XCTAssertNil(created.reason)
        let trip = try XCTUnwrap(preferences.ledger.trip("trip-1"))
        XCTAssertEqual([trip.name, String(trip.budgetKRW ?? 0)], ["오사카", "800000.0"])
        XCTAssertNil(created.appChange?.ledgerTrip?.before, "이 명령이 장부를 만들었다")
        XCTAssertEqual(preferences.ledger.entries.filter { $0.transfer?.tripID == "trip-1" }.count, 2, "일상↔여행 예산 이체 짝 기록이 생긴다")

        let same = await model.applyAssistantAction(.setTripBudget(tripID: "trip-1", budgetKRW: 800_000), preferences: preferences)
        XCTAssertEqual(same.reason, "no_change")
        let cleared = await model.applyAssistantAction(.setTripBudget(tripID: "trip-1", budgetKRW: 0), preferences: preferences)
        XCTAssertNil(cleared.reason)
        XCTAssertNil(preferences.ledger.trip("trip-1")?.budgetKRW)
        XCTAssertEqual(cleared.appChange?.ledgerTrip?.before?.budgetKRW, 800_000)

        let restored = await model.undoAssistantEntry(logEntry(.setTripBudget, cleared), preferences: preferences)
        XCTAssertTrue(restored)
        XCTAssertEqual(preferences.ledger.trip("trip-1")?.budgetKRW, 800_000)
        let removed = await model.undoAssistantEntry(logEntry(.setTripBudget, created), preferences: preferences)
        XCTAssertTrue(removed)
        XCTAssertNil(preferences.ledger.trip("trip-1"), "없던 장부는 되돌리면 지운다")

        var value = try input()
        value.ledgerTrips = [LedgerTrip(id: "trip-1", name: "오사카", start: at(11, 1, 9), end: at(11, 4, 9), budgetKRW: 800_000, members: ["민수"])]
        let state = AssistantAppStateSync.make(value)
        XCTAssertEqual(state.ledger.trips?.map(\.id), ["trip-1"])
        XCTAssertEqual(state.ledger.trips?.first?.budgetKRW, 800_000)
        XCTAssertEqual(state.ledger.trips?.first?.ended, true)
        XCTAssertFalse(String(decoding: try XCTUnwrap(AssistantAppStateSync.body(state)), as: UTF8.self).contains("민수"), "동행 이름은 올리지 않는다")
    }

    /// ASN1112A01: 답하지 않은 질문은 앱이 앞으로 올 때 다시 알리고, iOS 알림 글은 잠금 중이면 질문을 싣지 않는다.
    func testWaitingQuestionsAreAnnouncedAgainAndTheNoticeHidesTextWhenLocked() throws {
        let store = defaults()
        let questions = AssistantQuestionStore(defaults: store)
        let first = try XCTUnwrap(AssistantQuestion.make(id: "q1", question: "어디였나요?", options: ["회사", "카페"], multiSelect: false, now: at(11, 12, 9)))
        let approval = try XCTUnwrap(AssistantApproval.make(request: "retentionDays", value: .number(7))).question(id: "a1", now: at(11, 12, 9))
        questions.add(first, now: at(11, 12, 9))
        questions.add(approval, now: at(11, 12, 9))
        XCTAssertEqual(questions.announced?.id, "a1")
        questions.announced = nil
        questions.reannounce()
        XCTAssertEqual(questions.announced?.id, "q1", "가장 오래 기다린 것부터 다시 알린다")
        questions.reannounce()
        XCTAssertEqual(questions.announced?.id, "q1", "알리는 중이면 바꾸지 않는다")
        XCTAssertTrue(questions.answer("q1", choices: ["카페"], text: nil, now: at(11, 12, 10)))
        XCTAssertNil(questions.announced)
        questions.reannounce()
        XCTAssertEqual(questions.announced?.id, "a1")
        questions.skip("a1", now: at(11, 12, 10))
        questions.reannounce()
        XCTAssertNil(questions.announced, "기다리는 것이 없으면 알리지 않는다")

        let open = AssistantQuestionNotice.content(first, language: .korean, locked: false)
        XCTAssertEqual([open.title, open.body], ["AI 질문", "어디였나요?"])
        let locked = AssistantQuestionNotice.content(first, language: .korean, locked: true)
        XCTAssertEqual([locked.title, locked.body], ["AI 질문", "앱에서 확인해 주세요."])
        let ask = AssistantQuestionNotice.content(approval, language: .korean, locked: false)
        XCTAssertEqual(ask.title, "AI 승인 요청")
        XCTAssertTrue(ask.body.contains("보관 기간"))
        XCTAssertEqual(AssistantQuestionNotice.identifier("q1"), "assistant-question-q1")
    }

    func testOpenScreenWaitsUntilTakenExpiresAndUndoCancelsIt() async throws {
        let store = defaults()
        let model = await model()
        let preferences = AssistantPreferenceStore.test(store)
        let result = await model.applyAssistantAction(.openScreen(.paymentAutomation), preferences: preferences)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.appChange?.screen, .paymentAutomation)
        XCTAssertEqual(preferences.screens.pending, .paymentAutomation)
        XCTAssertEqual(AssistantScreenRequest(defaults: store).pending, .paymentAutomation, "앱이 다시 켜져도 남는다")
        XCTAssertTrue(model.snapshot.plans.isEmpty && model.snapshot.memos.isEmpty, "자료는 바꾸지 않는다")

        let newer = await model.applyAssistantAction(.openScreen(.ledger), preferences: preferences)
        XCTAssertEqual(preferences.screens.pending, .ledger, "새 요청이 앞의 것을 바꾼다")
        let ignored = await model.undoAssistantEntry(logEntry(.openScreen, result), preferences: preferences)
        XCTAssertTrue(ignored)
        XCTAssertEqual(preferences.screens.pending, .ledger, "다른 화면 요청은 거두지 않는다")
        let undone = await model.undoAssistantEntry(logEntry(.openScreen, newer), preferences: preferences)
        XCTAssertTrue(undone)
        XCTAssertNil(preferences.screens.pending)

        let requests = AssistantScreenRequest(defaults: store)
        requests.request(.settings, now: at(11, 12, 9))
        XCTAssertEqual(requests.take(now: at(11, 12, 10)), .settings)
        XCTAssertNil(requests.take(now: at(11, 12, 10)), "한 번만 띄운다")
        requests.request(.settings, now: at(11, 12, 9))
        XCTAssertNil(requests.take(now: at(11, 13, 10)), "하루가 지난 요청은 버린다")
        XCTAssertNil(requests.pending)
    }

    func testSetupTextExplainsAppStateAndTheNewCommands() {
        let key = String(repeating: "A", count: 43)
        let write = TripRelay.assistantSetupText(host: "relay.example.com", key: key, timeZone: calendar.timeZone)
        for part in ["GET /app", "get_app_state", "\"setBudget\"", "\"addOwnAccount\"", "removeOwnAccount", "\"deletePaymentRule\"", "\"resolveReview\"", "\"deleteInboxItem\"",
                     "\"openScreen\",\"screen\":\"paymentAutomation|shortcuts|aiConnection|ledger|dataProtection|settings|salary|carAudio|alarm|placeBook|passport|unconfirmedReview|travel\"",
                     "cannot create or switch on an iOS automation", "turn the switch on myself", "no_review"] {
            XCTAssertTrue(write.contains(part), part)
        }
        let read = TripRelay.assistantSetupText(host: "relay.example.com", key: key, scope: .read, timeZone: calendar.timeZone)
        XCTAssertTrue(read.contains("GET /app"))
        XCTAssertFalse(read.contains("openScreen"), "읽기 키에는 쓰기 안내가 없다")
    }

    private func input() throws -> AssistantAppStateSync.Input {
        let rule = try LedgerMessageRules.validated(name: "OO카드", pattern: "OO카드 (?<amount>[0-9,]+)원", sample: "OO카드 1,000원", kind: .expense).get()
        var canceled = LedgerEntry(occurredAt: at(11, 11, 20), amount: 9_000, title: "환불한 저녁", source: .message)
        canceled.canceledAt = at(11, 11, 21)
        return AssistantAppStateSync.Input(
            now: at(11, 12, 10), calendar: calendar, language: "korean", mapStyle: .mapLibreNight,
            display: ["mapPhotos": true, "mapRoutes": false, "mapFootprints": true], shareLevel: .summary, retentionDays: 7,
            aiConnections: 2, actionsOff: [.deleteMemo, .openScreen], paymentShortcutLink: true,
            entries: [
                canceled,
                LedgerEntry(occurredAt: at(11, 12, 8, 41), amount: 12_000, category: .cafe, title: "스타벅스 1234-5678-9012-3456", source: .message),
            ],
            budgetKRW: 500_000, spentKRW: 12_000, incomeKRW: 0, ownAccounts: ["비상금 통장", "110-123-456789"],
            review: [.init(entry: LedgerEntry(occurredAt: at(11, 12, 9), amount: 3_000, title: "결제", source: .message), reason: .noMerchant, receivedAt: at(11, 12, 9, 1))],
            inbox: [.init(text: "OO카드 1234567890123 승인 " + String(repeating: "가", count: 400), receivedAt: at(11, 12, 8, 41), outcome: .unread, message: "읽지 못했어요")],
            rules: [rule]
        )
    }

    func testAppStateCarriesSettingsLedgerReviewInboxAndRulesWithNumbersMasked() throws {
        let state = AssistantAppStateSync.make(try input())
        XCTAssertEqual([state.format, state.timeZone, state.settings.language, state.settings.mapStyle, state.settings.shareLevel],
                       ["bokki-app", "Asia/Seoul", "korean", "mapLibreNight", "summary"])
        XCTAssertEqual(state.settings.theme, "navy")
        XCTAssertEqual(state.settings.actionsOff, ["deleteMemo", "openScreen"])
        XCTAssertEqual([state.settings.aiConnections, state.settings.paymentTexts, state.retentionDays], [2, 1, 7])
        XCTAssertEqual(state.settings.lastPaymentTextAt, "2026-11-12T08:41+09:00")
        XCTAssertEqual([state.ledger.month, state.ledger.budgetKRW.map { "\($0)" } ?? "", "\(state.ledger.spentKRW)"], ["2026-11", "500000.0", "12000.0"])
        XCTAssertEqual(state.ledger.ownAccounts, ["비상금 통장", "***-***-**6789"], "번호처럼 보이는 이름은 가린다")
        XCTAssertEqual(state.ledger.entries.map(\.title), ["스타벅스 ****-****-****-3456", "환불한 저녁"], "새 것부터, 번호는 가린다")
        XCTAssertEqual(state.ledger.entries.map(\.canceled), [false, true])
        XCTAssertEqual([state.ledger.entries[0].category, state.ledger.entries[0].kind, state.ledger.entries[0].source, state.ledger.entries[0].time],
                       ["cafe", "expense", "message", "2026-11-12T08:41+09:00"])
        XCTAssertEqual([state.review[0].reason, state.review[0].title, state.review[0].time], ["noMerchant", "결제", "2026-11-12T09:00+09:00"])
        XCTAssertEqual(state.inbox[0].outcome, "unread")
        XCTAssertTrue(state.inbox[0].text.hasPrefix("OO카드 *********0123 승인"))
        XCTAssertEqual(state.inbox[0].text.count, AssistantAppStateSync.inboxTextLimit)
        XCTAssertEqual(state.rules.map(\.name), ["OO카드"])
        XCTAssertEqual(state.rules[0].pattern, "OO카드 (?<amount>[0-9,]+)원")

        // 올리는 글에 좌표·백업·키 같은 칸은 없다.
        let json = try XCTUnwrap(String(data: try XCTUnwrap(AssistantAppStateSync.body(state)), encoding: .utf8))
        for word in ["latitude", "longitude", "backup", "token", "sample", "payer", "note", "1234567890123", "110-123-456789"] {
            XCTAssertFalse(json.contains(word), word)
        }
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(top.keys), ["format", "version", "retentionDays", "timeZone", "settings", "ledger", "review", "inbox", "rules"])
    }

    func testAppStateHashIgnoresTheStampAndTheBodyFitsTheServerLimit() throws {
        var source = try input()
        var state = AssistantAppStateSync.make(source)
        let tag = AssistantAppStateSync.hash(state)
        state.updatedAt = "2026-11-12T10:00+09:00"
        XCTAssertEqual(AssistantAppStateSync.hash(state), tag)
        state.ledger.budgetKRW = 1
        XCTAssertNotEqual(AssistantAppStateSync.hash(state), tag)

        source.entries = (0..<500).map { LedgerEntry(occurredAt: at(11, 1, 0).addingTimeInterval(Double($0) * 60), amount: Double($0 + 1), title: String(repeating: "가", count: 60)) }
        let large = AssistantAppStateSync.make(source)
        XCTAssertEqual(large.ledger.entries.count, AssistantAppStateSync.entryLimit)
        XCTAssertEqual(large.ledger.entries.first?.amount, 500, "새 것부터 100개")
        let small = try XCTUnwrap(AssistantAppStateSync.body(large, limit: 12_000))
        XCTAssertLessThanOrEqual(small.count, 12_000)
        let kept = try JSONDecoder().decode(AssistantAppState.self, from: small)
        XCTAssertLessThan(kept.ledger.entries.count, 100)
        XCTAssertEqual(kept.ledger.entries.first?.amount, 500, "덜어 낼 때도 새 것을 남긴다")
        XCTAssertEqual(kept.rules, large.rules)
    }

    func testAppStateUploadsOnceThenOnlyWhenChangedAndIsDeletedWhenSharingIsOff() async throws {
        let store = defaults()
        let model = await model()
        let master = "m".padding(toLength: 43, withPad: "a", startingAt: 0)
        Phase3RelayStub.reset { $0.httpMethod == "DELETE" ? 204 : 201 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase3RelayStub.self]
        let env = AssistantRegistration.Environment(
            secrets: AssistantMemorySecrets([.master: master]), defaults: store, session: URLSession(configuration: configuration),
            host: "relay.example.com", clearConnections: {}
        )
        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 12, 10))
        XCTAssertEqual(Phase3RelayStub.requests.map(\.summary), ["POST /app"])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Phase3RelayStub.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(sent["format"] as? String, "bokki-app")
        XCTAssertNotNil(sent["updatedAt"])
        XCTAssertEqual(Phase3RelayStub.requests.first?.token, master)

        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 12, 11))
        XCTAssertEqual(Phase3RelayStub.requests.count, 1, "바뀌지 않았으면 다시 올리지 않는다")
        LedgerOwnAccounts.set(["비상금 통장"], defaults: store)
        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 12, 12))
        XCTAssertEqual(Phase3RelayStub.requests.count, 2)
        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 13, 9))
        XCTAssertEqual(Phase3RelayStub.requests.count, 3, "서버 보관이 끝나기 전에 다시 올린다")

        store.set(AssistantShareLevel.off.rawValue, forKey: AssistantShareLevel.defaultsKey)
        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 13, 10))
        XCTAssertEqual(Phase3RelayStub.requests.last?.summary, "DELETE /app")
        await AssistantAppStateSync.run(model: model, defaults: store, env: env, now: at(11, 13, 11))
        XCTAssertEqual(Phase3RelayStub.requests.count, 4, "지운 뒤에는 아무것도 보내지 않는다")
    }
}
