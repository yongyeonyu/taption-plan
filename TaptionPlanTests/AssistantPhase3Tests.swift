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
        XCTAssertEqual(AssistantAIProvider.featured, [.pickle, .chatGPT, .claude, .gemini])
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
