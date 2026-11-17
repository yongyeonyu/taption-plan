import XCTest
@testable import TaptionPlan
import TaptionLedgerCore
import TaptionPlanCore
import TaptionPlanStore
import TaptionTripShare
import TaptionTripShareTesting

/// 여행 공유 앱 0단계(TSH1114A26): 변환·id·곁 파일·키 보관·링크·투영·가드.
@MainActor
final class TripShareFoundationTests: XCTestCase {
    private var originalStore: TripShareStore!
    private var folder: URL!

    override func setUp() async throws {
        originalStore = TripShareStore.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TripShareFoundationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        TripShareStore.shared = originalStore
        TripShareInbox.shared.pending = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func stamp(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func item(_ id: String, _ title: String, _ start: String, _ end: String, offset: Int = 32_400, endOffset: Int? = nil, kind: String = "sight") -> TravelTripItem {
        TravelTripItem(
            tripID: "t1", itemID: id, kind: kind, title: title, start: stamp(start), end: stamp(end),
            startOffsetSeconds: offset, endOffsetSeconds: endOffset ?? offset, planID: nil
        )
    }

    private func environment(transport: (any ShareTransport)? = ShareFakeServer().transport) -> TripShareEnvironment {
        TripShareEnvironment(transport: transport, secrets: TripShareMemorySecrets(), sidecar: TripShareSidecar(directory: folder), appKey: { "test-app-key" })
    }

    private func makeModel(_ repository: any PlanDataRepository = InMemoryPlanRepository(snapshot: .empty)) async -> AppModel {
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    /// 여행 `t1`을 함께 쓰는 중으로 만든다(서버 없이 연결만).
    private func shareTrip(_ tripID: String = "t1", phase: TripShareLink.Phase = .sharing) throws -> TripShareLink {
        let store = TripShareStore(environment: environment())
        TripShareStore.shared = store
        let link = TripShareLink(roomID: ShareIdentifiers.roomID(), tripID: tripID, role: .owner, phase: phase)
        try store.save(link)
        return link
    }

    // MARK: 변환

    func testPlanRoundTripsThroughRoomContent() throws {
        var parent = item("m-1a2b3c4d", "성", "2031-10-02T01:00:00Z", "2031-10-02T03:30:00Z")
        parent.colorHex = "#AA3322"
        parent.plannedSpendKRW = 12_000
        parent.status = "booked"
        parent.note = "표는 미리"
        var detail = item("ai item/7", "천수각", "2031-10-02T01:30:00Z", "2031-10-02T02:00:00Z", kind: "photo")
        detail.parentItemID = parent.itemID
        // 밤 11시에 떠나 다른 시간대에 다음 날 닿는 비행.
        let flight = item("m-9f8e7d6c", "비행", "2031-10-02T14:00:00Z", "2031-10-02T19:30:00Z", offset: 32_400, endOffset: 25_200, kind: "flight")
        let local = [parent, detail, flight]

        for original in local {
            let roomID = TripShareMapping.roomItemID(tripID: "t1", itemID: original.itemID)
            XCTAssertTrue(ShareIdentifiers.isItemID(roomID), roomID)
            let content = TripShareMapping.plan(original, place: "어느 성", by: 1)
            // 평문을 실제로 글자로 만들었다 읽어도 같다.
            let decoded = try ShareContent.decode(kind: ShareKind.plan.rawValue, json: try ShareContent.plan(content).json())
            guard case .plan(let read) = decoded else { return XCTFail("plan") }
            let draft = try XCTUnwrap(TripShareMapping.draft(read, roomItemID: roomID, tripID: "t1", existing: local))
            XCTAssertEqual(draft.item, original)
            XCTAssertEqual(draft.place, "어느 성")
        }
        let flightContent = TripShareMapping.plan(flight)
        XCTAssertEqual([flightContent.day, "\(flightContent.start ?? -1)", "\(flightContent.end ?? -1)"], ["2031-10-02", "1380", "1590"], "끝은 끝 쪽 시차의 벽시계라 자정을 넘는다")
        XCTAssertEqual(TripShareMapping.plan(detail).parentItemID, TripShareMapping.roomItemID(tripID: "t1", itemID: parent.itemID), "부모는 방 id로 싣는다")

        // 다른 기기(그 일정이 없는 참여자)는 방 id를 로컬 번호로 쓴다.
        let joined = TripShareMapping.joinedTripID(roomID: ShareIdentifiers.roomID())
        let roomID = TripShareMapping.roomItemID(tripID: "t1", itemID: detail.itemID)
        let remote = try XCTUnwrap(TripShareMapping.draft(TripShareMapping.plan(detail), roomItemID: roomID, tripID: joined, existing: []))
        XCTAssertEqual([remote.item.tripID, remote.item.itemID], [joined, roomID])
        XCTAssertEqual(remote.item.parentItemID, TripShareMapping.roomItemID(tripID: "t1", itemID: parent.itemID))
        XCTAssertEqual(TripShareMapping.roomItemID(tripID: joined, itemID: roomID), roomID, "방에서 만든 번호는 그대로 방 id다")

        XCTAssertNil(TripShareMapping.draft(SharePlanContent(day: "2031-13-40", start: 60, end: 120, title: "x"), roomItemID: roomID, tripID: "t1", existing: []))
        XCTAssertNil(TripShareMapping.draft(SharePlanContent(day: "2031-10-02", start: 120, end: 60, title: "x"), roomItemID: roomID, tripID: "t1", existing: []))
    }

    func testItemIdentifiersAreStableAndReversible() {
        let first = TripShareMapping.roomItemID(tripID: "t1", itemID: "m-1a2b3c4d")
        XCTAssertEqual(first, TripShareMapping.roomItemID(tripID: "t1", itemID: "m-1a2b3c4d"))
        XCTAssertNotEqual(first, TripShareMapping.roomItemID(tripID: "t2", itemID: "m-1a2b3c4d"))
        XCTAssertEqual(first.utf8.count, 22)
        let items = [item("m-1a2b3c4d", "a", "2031-10-02T01:00:00Z", "2031-10-02T02:00:00Z")]
        XCTAssertEqual(TripShareMapping.localItemID(roomItemID: first, tripID: "t1", items: items), "m-1a2b3c4d")
        let fresh = ShareIdentifiers.itemID()
        XCTAssertEqual(TripShareMapping.localItemID(roomItemID: fresh, tripID: "t1", items: items), fresh)

        let entryID = UUID()
        let roomID = TripShareMapping.roomItemID(entryID: entryID)
        XCTAssertEqual(roomID.utf8.count, 22)
        XCTAssertEqual(TripShareMapping.entryID(roomItemID: roomID), entryID)
        XCTAssertNil(TripShareMapping.entryID(roomItemID: "member-3"))
    }

    /// 방이나 입력칸의 터무니없는 값이 앱을 멈추지 않는다(REV1117A01).
    func testAbsurdValuesNeitherCrashNorOverflow() {
        XCTAssertEqual(TripShareMapping.minorUnits(.infinity, currency: "KRW"), 0)
        XCTAssertEqual(TripShareMapping.minorUnits(.nan, currency: "USD"), 0)
        XCTAssertEqual(TripShareMapping.minorUnits(1e30, currency: "USD"), ShareSettlementCalculator.maxAmount)
        XCTAssertEqual(TripShareMapping.minorUnits(12.34, currency: "USD"), 1_234)
        XCTAssertEqual(TripShareMapping.clampedWhole(-1e30), -ShareSettlementCalculator.maxAmount)
        let huge = SharePlanContent(day: "2031-10-02", start: Int.max, title: "x")
        XCTAssertNil(TripShareMapping.draft(huge, roomItemID: "plan-00000001", tripID: "t1", existing: []))
    }

    func testExpensesRoundTripWithNames() throws {
        let cards = [1: ShareMemberCard(name: "가을", color: "#111111"), 2: ShareMemberCard(name: "가을", color: "#222222"), 3: ShareMemberCard(name: "봄", color: "#333333")]
        let names = TripShareNames(me: 2, cards: cards, guests: [ShareGuest(id: 1, name: "봄")])
        XCTAssertEqual(names.parties.map(names.name), ["가을", "가을 (2)", "봄", "봄 (2)"], "같은 닉네임은 번호 순으로 가른다")
        XCTAssertEqual(names.ledgerName(.member(2)), LedgerTrip.me)
        XCTAssertEqual(names.others, ["가을", "봄", "봄 (2)"])
        XCTAssertEqual(names.party(ledgerName: nil), .member(2))
        XCTAssertEqual(names.party(ledgerName: "봄 (2)"), .guest(1))

        var entry = LedgerEntry(
            occurredAt: Date(timeIntervalSince1970: 1_950_000_000), amount: 4_500, currency: "JPY", amountKRW: 41_230,
            category: .food, title: "저녁", payer: "가을", tripID: "t1", note: "셋이서", shareNames: [LedgerTrip.me, "가을", "봄 (2)"]
        )
        let content = try XCTUnwrap(TripShareMapping.sharedExpense(entry, names: names, by: 2))
        XCTAssertEqual([content.amount, content.amountKRW ?? 0], [4_500, 41_230])
        XCTAssertEqual(content.payer, .member(1))
        XCTAssertEqual(content.split, [.member(1), .member(2), .guest(1)])
        let roomID = TripShareMapping.roomItemID(entryID: entry.id)
        let back = try XCTUnwrap(TripShareMapping.entry(content, roomItemID: roomID, tripID: "t1", names: names))
        XCTAssertEqual(back.id, entry.id)
        XCTAssertEqual([back.title, back.currency, back.payer ?? "", back.note ?? ""], ["저녁", "JPY", "가을", "셋이서"])
        XCTAssertEqual([back.amount, back.amountKRW ?? 0], [4_500, 41_230])
        XCTAssertEqual(back.occurredAt, entry.occurredAt)
        XCTAssertEqual(back.category, .food)
        XCTAssertEqual(Set(back.shareNames ?? []), Set(entry.shareNames ?? []))

        // 내가 냈고 「다 같이」면 지금의 사람들을 그대로 적는다.
        entry.payer = nil
        entry.shareNames = nil
        entry.currency = "USD"
        entry.amount = 12.34
        let everyone = try XCTUnwrap(TripShareMapping.sharedExpense(entry, names: names))
        XCTAssertEqual(everyone.payer, .member(2))
        XCTAssertEqual(everyone.split, names.parties)
        XCTAssertEqual(everyone.amount, 1_234, "가장 작은 단위 정수")
        XCTAssertNil(try XCTUnwrap(TripShareMapping.entry(everyone, roomItemID: roomID, tripID: "t1", names: names)).payer, "내가 냈으면 비운다")
        XCTAssertEqual(TripShareMapping.entry(everyone, roomItemID: roomID, tripID: "t1", names: names)?.amount, 12.34)

        entry.payer = "모르는 사람"
        XCTAssertNil(TripShareMapping.sharedExpense(entry, names: names))
        entry.payer = nil
        entry.kind = .income
        XCTAssertNil(TripShareMapping.sharedExpense(entry, names: names), "수입은 올리지 않는다")
        entry.kind = .expense

        let own = try XCTUnwrap(TripShareMapping.ownExpense(entry, by: 2))
        let mine = try XCTUnwrap(TripShareMapping.entry(own, roomItemID: roomID, tripID: "t1"))
        XCTAssertEqual(mine.shareNames, TripShareMapping.privateShare, "개인 지출의 몫은 나만")
        XCTAssertEqual([mine.title, mine.currency], ["저녁", "USD"])
        XCTAssertNil(ShareContent.ownExpense(own, visibility: .hidden), "비공개는 올릴 것이 없다")
    }

    func testTripMetaRoundTripsAndKeepsLocalFlag() {
        let trip = TravelTrip(
            id: "t1", title: "가을 여행", startDay: "2031-10-01", endDay: "2031-10-04", countryCode: "JP", regionName: "간사이",
            latitude: 12.3456, longitude: 65.4321, currencyCode: "JPY", timeZoneID: "Asia/Tokyo", flagColorHex: "#123456",
            columns: [TravelTripColumn(name: "이동: 아침", kinds: ["transfer", "flight"]), TravelTripColumn(name: "", kinds: ["meal", "cafe", "sight"])]
        )
        let meta = TripShareMapping.meta(trip, budget: 900_000, guests: [ShareGuest(id: 1, name: "봄")], shareAllExpenses: true)
        XCTAssertEqual(TripShareMapping.trip(meta, id: "t1", existing: trip), trip)
        let fresh = TripShareMapping.trip(meta, id: "s-x")
        XCTAssertEqual([fresh.title, fresh.startDay, fresh.endDay, fresh.currencyCode ?? ""], ["가을 여행", "2031-10-01", "2031-10-04", "JPY"])
        XCTAssertEqual(fresh.columns, trip.columns)
        XCTAssertNil(fresh.latitude, "깃발 좌표는 방으로 가지 않는다")
        XCTAssertNil(TripShareMapping.trip(TripShareMapping.meta(TravelTrip(id: "k", title: "국내", startDay: "2031-10-01", endDay: "2031-10-01")), id: "k").currencyCode)
    }

    /// 대표 결정: 좌표는 방에 올리지 않고 장소 이름만.
    func testRoomContentCarriesNoCoordinates() throws {
        let trip = TravelTrip(id: "t1", title: "여행", startDay: "2031-10-01", endDay: "2031-10-02", latitude: 12.345678, longitude: 98.765432)
        let stop = TravelPlanStop(id: UUID(), title: "어느 다리", latitude: 12.345678, longitude: 98.765432, day: stamp("2031-10-01T00:00:00Z"), order: 0, planID: nil, tripID: "t1", itemID: "m-1a2b3c4d")
        let plan = TripShareMapping.plan(item("m-1a2b3c4d", "산책", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z"), place: stop.title)
        let notice = ShareNoticeContent(text: "세 시까지", createdAt: 1, due: 2, place: stop.title)
        let texts = try [ShareContent.plan(plan), .meta(TripShareMapping.meta(trip)), .notice(notice)].map { String(decoding: try $0.json(), as: UTF8.self) }
        for text in texts {
            for banned in ["12.34", "98.76", "latitude", "longitude", "\"lat\"", "\"lng\"", "coordinate"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(text)")
            }
        }
        XCTAssertTrue(texts[0].contains("어느 다리"))
    }

    // MARK: 링크·곁 파일·키 보관

    func testInviteLinkIsAppSchemeOnlyAndTheInboxKeepsIt() throws {
        let invite = ShareInvite.make()
        let url = try XCTUnwrap(TripShareEnvironment.inviteURL(invite))
        XCTAssertEqual(url.absoluteString, "taptionplan://share#" + invite.fragment)
        XCTAssertEqual(TripShareEnvironment.invite(from: "  " + url.absoluteString + "\n"), invite)
        XCTAssertNil(TripShareEnvironment.invite(from: "https://example.com/share#" + invite.fragment))
        XCTAssertNil(TripShareEnvironment.invite(from: "taptionplan://today#" + invite.fragment))
        XCTAssertNil(TripShareEnvironment.invite(from: "taptionplan://share#abc.def"))

        XCTAssertTrue(TripShareInbox.shared.receive(url))
        XCTAssertEqual(TripShareInbox.shared.pending, invite)
        TripShareInbox.shared.pending = nil
        XCTAssertFalse(TripShareInbox.shared.receive(try XCTUnwrap(URL(string: "taptionplan://share#nope"))))
        XCTAssertNil(TripShareInbox.shared.pending)
    }

    func testDeepLinkPutsTheInviteInTheInbox() async throws {
        let model = await makeModel()
        let invite = ShareInvite.make()
        await model.openDeepLink(try XCTUnwrap(TripShareEnvironment.inviteURL(invite)))
        XCTAssertEqual(TripShareInbox.shared.pending, invite)
        XCTAssertNil(model.pendingMapHomeRoute, "다른 화면 이동을 남기지 않는다")
    }

    func testSidecarKeepsLinkAndRoomCopyInOneFile() throws {
        let sidecar = TripShareSidecar(directory: folder)
        XCTAssertEqual(sidecar.links(), [])
        var link = TripShareLink(roomID: ShareIdentifiers.roomID(), tripID: "t1", role: .owner, phase: .uploading, joinedAt: Date(timeIntervalSince1970: 1_950_000_000))
        try sidecar.save(link)
        // 방 사본은 패키지가 만드는 값이라 저장된 모양(JSON)에서 읽어 만든다.
        let limits = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShareLimits.v1))
        let stored: [String: Any] = [
            "format": 1, "roomID": link.roomID, "me": 1, "epoch": 1, "rev": 7, "cursor": 7, "closed": false, "expiresAt": 9, "members": [Any](),
            "items": [["id": "trip-meta", "kind": "meta", "rev": 1, "seq": 1, "epoch": 1, "updatedAt": 1, "by": 1, "createdBy": 1, "acks": [String: Int](), "json": "{\"v\":1}"]],
            "unreadable": [Any](), "limits": limits,
        ]
        let room = try JSONDecoder().decode(ShareRoomSnapshot.self, from: JSONSerialization.data(withJSONObject: stored))
        try sidecar.save(room)
        link.phase = .sharing
        link.uploaded = ["a", "b"]
        try sidecar.save(link)

        XCTAssertEqual(sidecar.links(), [link])
        XCTAssertEqual(sidecar.link(roomID: link.roomID), link)
        XCTAssertEqual(sidecar.snapshot(roomID: link.roomID), room, "연결을 고쳐 적어도 방 사본은 남는다")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, [link.roomID + ".json"])
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, "기기 백업에서 뺀다")
        let text = try String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertFalse(text.contains("token") || text.contains("root"), "키·토큰은 곁 파일에 없다")

        XCTAssertThrowsError(try sidecar.save(TripShareLink(roomID: "../escape", tripID: "t", role: .member, phase: .sharing)))
        try sidecar.remove(roomID: link.roomID)
        XCTAssertEqual(sidecar.links(), [])
        XCTAssertNil(sidecar.snapshot(roomID: link.roomID))
    }

    /// 빈 방 사본(패키지가 만드는 값이라 저장된 모양에서 읽어 만든다).
    private func emptyRoom(_ roomID: String, me: Int) throws -> ShareRoomSnapshot {
        let limits = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShareLimits.v1))
        let stored: [String: Any] = [
            "format": 1, "roomID": roomID, "me": me, "epoch": 1, "rev": 0, "cursor": 0, "closed": false, "expiresAt": 9, "members": [Any](),
            "items": [Any](), "unreadable": [Any](), "limits": limits,
        ]
        return try JSONDecoder().decode(ShareRoomSnapshot.self, from: JSONSerialization.data(withJSONObject: stored))
    }

    /// 방 사본 한 칸이 깨져도 연결은 남고, 다음 사본 쓰기가 연결을 지우지 않는다(TSA1117A01).
    func testABrokenRoomCopyKeepsTheLink() throws {
        let sidecar = TripShareSidecar(directory: folder)
        let link = TripShareLink(roomID: ShareIdentifiers.roomID(), tripID: "t1", role: .member, phase: .sharing, joinedAt: Date(timeIntervalSince1970: 1_950_000_000))
        try sidecar.save(link)
        let url = folder.appendingPathComponent(link.roomID + ".json")
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        file["room"] = ["roomID": link.roomID, "items": "깨짐"]
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        XCTAssertEqual(sidecar.links(), [link], "깨진 사본 때문에 연결을 잃지 않는다")
        XCTAssertNil(sidecar.snapshot(roomID: link.roomID), "깨진 사본은 없는 것으로 보고 방에서 다시 받는다")
        XCTAssertEqual(TripShareStore(environment: environment(transport: nil)).links, [], "서버 없는 빌드는 그대로 숨긴다")
        try sidecar.save(emptyRoom(link.roomID, me: 2))
        XCTAssertEqual(sidecar.link(roomID: link.roomID), link, "사본을 다시 써도 연결은 남는다")
        XCTAssertEqual(sidecar.snapshot(roomID: link.roomID)?.me, 2)

        // 연결이 없는 방(잊은 방)에는 늦게 온 사본 쓰기가 파일을 되살리지 않는다.
        let forgotten = ShareIdentifiers.roomID()
        try sidecar.save(emptyRoom(forgotten, me: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(forgotten + ".json").path))

        // 예전 형식(지난 이름 칸이 없는 파일)도 그대로 읽는다.
        let old: [String: Any] = ["format": 1, "link": try JSONSerialization.jsonObject(with: JSONEncoder().encode(link))]
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        XCTAssertEqual(sidecar.link(roomID: link.roomID), link)
        XCTAssertEqual(sidecar.formerNames(roomID: link.roomID), [:])
        try sidecar.saveFormerNames([3: "봄"], roomID: link.roomID)
        XCTAssertEqual(sidecar.formerNames(roomID: link.roomID), [3: "봄"])
        XCTAssertEqual(sidecar.link(roomID: link.roomID), link)
    }

    /// 키체인 저장은 고쳐 쓰기가 먼저이고 지우지 않는다: 고쳐 쓰기가 실패해도 예전 키가 남는다(TSA1117A01).
    func testKeychainSaveUpdatesInPlaceAndNeverDeletesFirst() throws {
        final class Fake: @unchecked Sendable {
            let lock = NSLock()
            var stored: Data?
            var calls: [String] = []
            var failUpdate = false
        }
        let fake = Fake()
        let writes = TripShareKeychain.Writes(
            update: { _, attributes in
                fake.lock.withLock {
                    fake.calls.append("update")
                    guard !fake.failUpdate else { return errSecInteractionNotAllowed }
                    guard fake.stored != nil else { return errSecItemNotFound }
                    fake.stored = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            add: { item in
                fake.lock.withLock {
                    fake.calls.append("add")
                    XCTAssertEqual(item[kSecAttrService as String] as? String, "com.taption.plan.tripshare", "항목 이름은 그대로")
                    fake.stored = item[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            }
        )
        let keychain = TripShareKeychain(writes: writes)
        let roomID = ShareIdentifiers.roomID()
        var secrets = ShareRoomSecrets(root: ShareBytes.random(32), linkSecret: ShareIdentifiers.linkSecret(), token: "token-1", ownerKey: nil, member: 2, epoch: 1)
        try keychain.save(secrets, roomID: roomID)
        XCTAssertEqual(fake.calls, ["update", "add"], "없으면 더한다")
        secrets.epoch = 2
        try keychain.save(secrets, roomID: roomID)
        XCTAssertEqual(fake.calls, ["update", "add", "update"], "있으면 고쳐 쓴다")
        let kept = fake.stored
        fake.failUpdate = true
        secrets.epoch = 3
        XCTAssertThrowsError(try keychain.save(secrets, roomID: roomID))
        XCTAssertEqual(fake.stored, kept, "고쳐 쓰기가 실패해도 예전 키는 남는다")
        XCTAssertEqual(try JSONDecoder().decode(ShareRoomSecrets.self, from: XCTUnwrap(kept)).epoch, 2)
    }

    func testSecretStoresRoundTrip() throws {
        let roomID = ShareIdentifiers.roomID()
        let secrets = ShareRoomSecrets(root: ShareBytes.random(32), linkSecret: ShareIdentifiers.linkSecret(), token: "token-1", ownerKey: "owner-1", member: 1, epoch: 3)
        let memory = TripShareMemorySecrets()
        XCTAssertNil(try memory.secrets(roomID: roomID))
        try memory.save(secrets, roomID: roomID)
        XCTAssertEqual(try memory.secrets(roomID: roomID), secrets)
        try memory.remove(roomID: roomID)
        XCTAssertNil(try memory.secrets(roomID: roomID))

        // 진짜 키체인은 시험용 서비스 이름으로만 건드린다. 시험 호스트에 키체인이 없으면 건너뛴다.
        let keychain = TripShareKeychain(service: "com.taption.plan.tripshare.tests")
        do { try keychain.save(secrets, roomID: roomID) } catch { throw XCTSkip("keychain unavailable in this test host") }
        defer { try? keychain.remove(roomID: roomID) }
        XCTAssertEqual(try keychain.secrets(roomID: roomID), secrets)
        var changed = secrets
        changed.token = "token-2"
        changed.epoch = 4
        try keychain.save(changed, roomID: roomID)
        XCTAssertEqual(try keychain.secrets(roomID: roomID), changed, "같은 방은 덮어쓴다")
        try keychain.remove(roomID: roomID)
        XCTAssertNil(try keychain.secrets(roomID: roomID))
        XCTAssertEqual(TripShareKeychain().service, "com.taption.plan.tripshare")
    }

    // MARK: 창구

    func testStoreHidesTheFeatureWithoutAServer() {
        let store = TripShareStore(environment: environment(transport: nil))
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.links, [])
        XCTAssertFalse(store.isShared("t1"))
    }

    func testStoreOpensARoomOnTheFakeServerAndForgetsIt() async throws {
        let server = ShareFakeServer()
        let store = TripShareStore(environment: environment(transport: server.transport))
        let invite = ShareInvite.make()
        let keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: "가을여행-2031", iterations: 20)
        let ownerKey = ShareIdentifiers.ownerKey()
        let registered = await store.appKey()
        let appKey = try XCTUnwrap(registered)
        let entry = try await ShareRoomClient.createRoom(
            transport: server.transport, appKey: appKey,
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 86_400_000)
        )
        let link = TripShareLink(roomID: invite.roomID, tripID: "t1", role: .owner, phase: .uploading)
        try store.register(link, secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, ownerKey: ownerKey, member: entry.member, epoch: entry.epoch))
        XCTAssertTrue(store.isShared("t1"))
        XCTAssertFalse(store.canEdit("t1"), "열기 전에는 보기만")

        let opened = await store.open(tripID: "t1")
        let session = try XCTUnwrap(opened)
        for _ in 0..<1_000 where await session.view().status != .live { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await session.publish(card: ShareMemberCard(name: "가을", color: "#112233"))
        _ = try await session.publish(meta: TripShareMapping.meta(TravelTrip(id: "t1", title: "여행", startDay: "2031-10-01", endDay: "2031-10-02"), budget: 500_000))
        await store.refresh(tripID: "t1")
        XCTAssertTrue(store.canEdit("t1"))
        XCTAssertEqual(store.memberCount(tripID: "t1"), 1)
        XCTAssertEqual(store.names(tripID: "t1")?.name(.member(1)), "가을")
        XCTAssertEqual(store.view(tripID: "t1")?.meta?.budget, 500_000, "공유 예산은 방(곁 파일)에만 있다")
        XCTAssertEqual(store.lockState(tripID: "t1", itemID: "m-1a2b3c4d"), .free)

        await store.close(tripID: "t1")
        XCTAssertNil(store.view(tripID: "t1"))
        XCTAssertEqual(store.memberCount(tripID: "t1"), 1, "닫은 뒤에는 곁 파일의 사람 수")
        let reopened = TripShareStore(environment: store.environment)
        XCTAssertEqual(reopened.links.map(\.tripID), ["t1"])
        XCTAssertEqual(reopened.memberCount(tripID: "t1"), 1)

        await store.forget(tripID: "t1")
        XCTAssertFalse(store.isShared("t1"))
        XCTAssertNil(try store.environment.secrets.secrets(roomID: invite.roomID))
        XCTAssertEqual(store.environment.sidecar.links(), [])
    }

    /// 열기·닫기·잊기가 겹쳐 불려도 차례대로 돈다: 닫은 방이 다시 살아나거나 잊은 방의 곁 파일이 되살아나지 않는다(TSA1117A01).
    func testOpenCloseAndForgetDoNotInterleave() async throws {
        let server = ShareFakeServer()
        let store = TripShareStore(environment: environment(transport: server.transport))
        let invite = ShareInvite.make()
        let keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: "가을여행-2031", iterations: 20)
        let ownerKey = ShareIdentifiers.ownerKey()
        let entry = try await ShareRoomClient.createRoom(
            transport: server.transport, appKey: "test-app-key",
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 86_400_000)
        )
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: "t1", role: .owner, phase: .sharing),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, ownerKey: ownerKey, member: entry.member, epoch: entry.epoch)
        )

        // 열기 도중에 닫기가 들어온다: 닫기가 이긴다(살아 있는 세션·화면 값이 남지 않는다).
        let opening = Task { await store.open(tripID: "t1") }
        let closing = Task { await store.close(tripID: "t1") }
        let opened = await opening.value
        await closing.value
        XCTAssertNil(store.session(tripID: "t1"), "닫은 뒤에 세션이 남지 않는다")
        XCTAssertNil(store.view(tripID: "t1"), "닫은 뒤에 화면 값이 남지 않는다")
        let status = await opened?.view().status
        XCTAssertNotEqual(status, .live, "닫은 세션이 다시 이어지지 않는다")

        // 닫기 도중에 잊기가 들어온다: 늦은 사본 쓰기가 곁 파일을 되살리지 않는다.
        await store.open(tripID: "t1")
        let closingAgain = Task { await store.close(tripID: "t1") }
        let forgetting = Task { await store.forget(tripID: "t1") }
        await closingAgain.value
        await forgetting.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.environment.sidecar.links(), [])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(left, [], "잊은 방의 곁 파일이 되살아나지 않는다")
        XCTAssertNil(try store.environment.secrets.secrets(roomID: invite.roomID))
    }

    /// 지구본에서 연 공유 판이 닫히면 그 방도 닫는다. 보고 있는 여행의 방은 그대로 둔다(TSA1117A01).
    func testClosingThePanelClosesARoomThatIsNotOnScreen() {
        XCTAssertEqual(TripShareHost.roomToClose(from: .panel(tripID: "t1"), to: nil, opened: nil), "t1")
        XCTAssertEqual(TripShareHost.roomToClose(from: .panel(tripID: "t1"), to: nil, opened: "t2"), "t1")
        XCTAssertNil(TripShareHost.roomToClose(from: .panel(tripID: "t1"), to: nil, opened: "t1"), "보고 있는 여행은 닫지 않는다")
        XCTAssertNil(TripShareHost.roomToClose(from: .panel(tripID: "t1"), to: .panel(tripID: "t1"), opened: nil))
        XCTAssertEqual(TripShareHost.roomToClose(from: .panel(tripID: "t1"), to: .panel(tripID: "t2"), opened: nil), "t1")
        XCTAssertNil(TripShareHost.roomToClose(from: .join(nil), to: nil, opened: nil))
        XCTAssertNil(TripShareHost.roomToClose(from: nil, to: .panel(tripID: "t1"), opened: nil))
    }

    // MARK: 투영·가드

    func testProjectionWritesManyChangesWithOneSave() async throws {
        let repository = PermissionCountingPlanRepository()
        let model = await makeModel(repository)
        let trip = TravelTrip(id: "t1", title: "여행", startDay: "2031-10-01", endDay: "2031-10-01")
        let drafts = (0..<12).map { index in
            TripShareMapping.PlanDraft(item: item(ShareIdentifiers.itemID(), "곳 \(index)", "2031-10-0\(1 + index / 6)T0\(index % 6):00:00Z", "2031-10-0\(1 + index / 6)T0\(index % 6):45:00Z"), place: "이름만")
        }
        var saves = await repository.saveCount
        let added = await model.applySharedPlanChanges(tripID: "t1", upserts: drafts, trip: trip)
        XCTAssertTrue(added)
        var after = await repository.saveCount
        XCTAssertEqual(after - saves, 1, "열두 건을 넣어도 저장은 한 번")
        let items = model.settings.travelTripItems ?? []
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(model.snapshot.plans.count, 12, "일상 쪽 계획이 함께 생긴다")
        XCTAssertTrue(items.allSatisfy { item in model.snapshot.plans.contains { $0.id == item.planID } })
        XCTAssertEqual(model.settings.travelPlanStops, [], "이름뿐인 장소로 핀을 만들지 않는다")
        XCTAssertEqual(model.settings.travelTrips?.first?.endDay, "2031-10-02", "일정이 기간 밖이면 기간을 늘린다")

        // 같은 것을 다시 넣으면 저장하지 않는다.
        saves = after
        let same = await model.applySharedPlanChanges(tripID: "t1", upserts: items.map { TripShareMapping.PlanDraft(item: $0, place: nil) })
        XCTAssertTrue(same)
        after = await repository.saveCount
        XCTAssertEqual(after - saves, 0)

        // 고치기와 지우기가 섞여도 한 번.
        var moved = items[0]
        moved.title = "바뀐 이름"
        moved.end = moved.end.addingTimeInterval(900)
        moved.planID = nil
        saves = after
        let changed = await model.applySharedPlanChanges(tripID: "t1", upserts: [.init(item: moved, place: nil)], removedItemIDs: [items[1].itemID, items[2].itemID])
        XCTAssertTrue(changed)
        after = await repository.saveCount
        XCTAssertEqual(after - saves, 1)
        XCTAssertEqual(model.settings.travelTripItems?.count, 10)
        XCTAssertEqual(model.snapshot.plans.count, 10, "지운 일정의 일상 계획도 사라진다")
        let plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == items[0].planID })
        XCTAssertEqual(plan.title, "바뀐 이름")
        XCTAssertEqual(plan.span.end, moved.end)
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == moved.itemID }?.planID, items[0].planID, "고쳐도 계획 연결은 그대로")
    }

    func testSharedTripRefusesImportShiftStatusAndAssistantEdits() async throws {
        let model = await makeModel()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "여행", startDay: "2031-10-01", endDay: "2031-10-02"))
        XCTAssertTrue(saved)
        let addedID = await model.addTripItem(
            tripID: "t1", kind: .sight, title: "산책", start: stamp("2031-10-01T01:00:00Z"), end: stamp("2031-10-01T02:00:00Z"), offsetSeconds: 32_400
        )
        let itemID = try XCTUnwrap(addedID)
        let before = model.settings.travelTripItems
        _ = try shareTrip()
        XCTAssertTrue(model.isSharedTrip("t1"))
        XCTAssertFalse(model.isSharedTrip("t2"))

        let plan = try TripImportParser.parse(#"""
        {"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[
         {"id":"a","type":"sight","title":"다른 곳","start":"2031-10-02T09:00+09:00"}]}
        """#).get()
        let imported = await model.applyTripImport(plan)
        XCTAssertFalse(imported, "같은 여행 다시 가져오기를 막는다")
        XCTAssertEqual(model.userFacingError, TripShareText.editBlocked(.current))
        model.userFacingError = nil
        let shifted = await model.shiftTravelTrip("t1", byDays: 2)
        XCTAssertFalse(shifted, "날짜 통째 옮기기를 막는다")
        XCTAssertNotNil(model.userFacingError)
        model.setTripItemStatus(.booked, tripID: "t1", itemID: itemID)
        XCTAssertEqual(model.settings.travelTripItems, before)

        // AI의 여행 편집은 `shared_trip`으로 거절한다.
        let name = "TripShareFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func reason(_ action: String, _ extra: [String: Any]) async throws -> String? {
            let command: [String: Any] = ["format": "bokki-command", "version": 1, "id": "c-\(UUID().uuidString)", "action": action].merging(extra) { $1 }
            let data = try JSONSerialization.data(withJSONObject: ["commands": [command]])
            let batch = try XCTUnwrap(AssistantCommandParser.parse(data, now: stamp("2031-09-01T00:00:00Z"), calendar: .autoupdatingCurrent))
            XCTAssertEqual(batch.invalidIDs, [], action)
            let applied = await model.applyAssistantCommands(batch, defaults: defaults)
            return try XCTUnwrap(applied).results.first?.reason
        }
        let added = try await reason("addTripItem", ["tripId": "t1", "title": "저녁", "start": "2031-10-01T19:00+09:00", "end": "2031-10-01T20:00+09:00"])
        let updated = try await reason("updateTripItem", ["tripId": "t1", "itemId": itemID, "title": "밤 산책"])
        let status = try await reason("setTripItemStatus", ["tripId": "t1", "itemId": itemID, "status": "booked"])
        let renamed = try await reason("updateTrip", ["tripId": "t1", "start": "2031-10-05"])
        XCTAssertEqual([added, updated, status, renamed], ["shared_trip", "shared_trip", "shared_trip", "shared_trip"])
        XCTAssertEqual(model.settings.travelTripItems, before, "아무것도 바뀌지 않았다")
        XCTAssertEqual(model.settings.travelTrips?.first?.startDay, "2031-10-01")
        XCTAssertEqual(AssistantRejection.message("shared_trip", language: .korean), "함께 쓰는 여행이라 AI가 바꾸지 않았어요")

        // 방이 끝나면 보통 여행으로 돌아와 다시 고칠 수 있다.
        var link = try XCTUnwrap(TripShareStore.shared.link(tripID: "t1"))
        link.phase = .ended
        try TripShareStore.shared.save(link)
        XCTAssertFalse(model.isSharedTrip("t1"))
        let shiftedAfter = await model.shiftTravelTrip("t1", byDays: 1)
        XCTAssertTrue(shiftedAfter)
    }

    /// TSF1115A01: 일상 시간표·계획 편집기·빠른 동작·AI는 함께 쓰는 여행의 일정에 묶인 계획 기록을 고치거나 지우지 못한다.
    /// 방에서 온 투영은 그대로 통과한다(여행 화면 편집의 왕복은 `TripSharePlanTests`).
    func testDailyPlanPathsCannotEditOrDeleteASharedTripPlan() async throws {
        let model = await makeModel()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "여행", startDay: "2031-10-01", endDay: "2031-10-02"))
        XCTAssertTrue(saved)
        let addedID = await model.addTripItem(
            tripID: "t1", kind: .sight, title: "산책", start: stamp("2031-10-01T01:00:00Z"), end: stamp("2031-10-01T02:00:00Z"), offsetSeconds: 32_400
        )
        let itemID = try XCTUnwrap(addedID)
        let planID = try XCTUnwrap(model.settings.travelTripItems?.first?.planID)
        let dailyID = try XCTUnwrap(model.addPlan(title: "장보기", categoryID: "activity", startAt: stamp("2031-10-01T05:00:00Z"), duration: 3_600))
        let plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
        XCTAssertFalse(model.rejectsSharedTripPlanEdit([planID]), "공유 전에는 보통 계획이다")
        _ = try shareTrip()
        XCTAssertTrue(model.isSharedTripPlan(planID))
        XCTAssertFalse(model.isSharedTripPlan(dailyID))
        let plans = model.snapshot.plans, items = model.settings.travelTripItems

        func assertBlocked(_ what: String, line: UInt = #line) {
            XCTAssertEqual(model.userFacingError, TripShareText.editBlocked(.current), what, line: line)
            XCTAssertEqual(model.snapshot.plans, plans, what, line: line)
            XCTAssertEqual(model.settings.travelTripItems, items, what, line: line)
            model.userFacingError = nil
        }
        model.updatePlan(planID, title: "다른 이름", categoryID: plan.categoryID, span: plan.span, parentID: nil, isImportant: true)
        assertBlocked("계획 편집기의 저장")
        model.movePlan(planID, by: 1_800)
        assertBlocked("시간표에서 끌어 옮기기")
        model.resizePlan(planID, endDelta: 600)
        assertBlocked("시간표에서 길이 바꾸기")
        await model.performQuickAction(.postponeThirtyMinutes, planID: planID)
        assertBlocked("30분 미루기")
        await model.performQuickAction(.moveToNextFreeTime, planID: planID)
        assertBlocked("다음 빈 시간으로")
        await model.deletePlan(planID)
        assertBlocked("계획 지우기")
        await model.deletePlans([dailyID, planID])
        assertBlocked("여럿을 함께 지울 때도 통째로 막는다")

        // AI의 일정 고치기·지우기·미루기는 `shared_trip`으로 거절한다.
        let name = "TripShareFoundationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func reason(_ action: String, _ extra: [String: Any]) async throws -> String? {
            let command: [String: Any] = ["format": "bokki-command", "version": 1, "id": "c-\(UUID().uuidString)", "action": action].merging(extra) { $1 }
            let data = try JSONSerialization.data(withJSONObject: ["commands": [command]])
            let batch = try XCTUnwrap(AssistantCommandParser.parse(data, now: stamp("2031-09-01T00:00:00Z"), calendar: .autoupdatingCurrent))
            XCTAssertEqual(batch.invalidIDs, [], action)
            let applied = await model.applyAssistantCommands(batch, defaults: defaults)
            return try XCTUnwrap(applied).results.first?.reason
        }
        let renamed = try await reason("updateSchedule", ["planId": planID.uuidString, "title": "밤 산책"])
        let deleted = try await reason("deleteSchedule", ["planId": planID.uuidString])
        let postponed = try await reason("planQuickAction", ["planId": planID.uuidString, "quickAction": "postpone30"])
        XCTAssertEqual([renamed, deleted, postponed], ["shared_trip", "shared_trip", "shared_trip"])
        XCTAssertEqual(model.snapshot.plans, plans)
        XCTAssertEqual(model.settings.travelTripItems, items)
        model.userFacingError = nil

        // 공유 여행과 상관없는 계획은 그대로 고치고 지운다.
        model.movePlan(dailyID, by: 1_800)
        XCTAssertNil(model.userFacingError)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == dailyID }?.span.start, stamp("2031-10-01T05:30:00Z"))
        await model.deletePlan(dailyID)
        XCTAssertFalse(model.snapshot.plans.contains { $0.id == dailyID })

        // 방에서 온 투영은 통과한다: 고치고, 지운다(딸린 계획 기록까지).
        var changed = try XCTUnwrap(items?.first)
        changed.title = "밤 산책"
        let projected = await model.applySharedPlanChanges(tripID: "t1", upserts: [TripShareMapping.PlanDraft(item: changed, place: nil)])
        XCTAssertTrue(projected)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == planID }?.title, "밤 산책")
        let removed = await model.applySharedPlanChanges(tripID: "t1", removedItemIDs: [itemID])
        XCTAssertTrue(removed)
        XCTAssertFalse(model.snapshot.plans.contains { $0.id == planID }, "방이 지운 일정의 계획 기록은 지워진다")
        XCTAssertNil(model.userFacingError)
    }

    func testEditorPassesUnsharedTripsAndBlocksUndoAndOfflineOnSharedOnes() async throws {
        let model = await makeModel()
        var ran = 0
        TripSharePlanEditor.route(model: model, tripID: "t1", edit: .history) { ran += 1 }
        XCTAssertEqual(ran, 1, "공유하지 않는 여행은 그대로 통과")
        _ = try shareTrip()
        TripSharePlanEditor.route(model: model, tripID: "t1", edit: .history) { ran += 1 }
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(TripShareStore.shared.notice, TripShareText.undoBlocked(.current))
        TripSharePlanEditor.route(model: model, tripID: "t1", edit: .open(itemID: "x")) { ran += 1 }
        XCTAssertEqual(ran, 1, "방을 열지 않았으면 보기만")
        XCTAssertEqual(TripShareStore.shared.notice, TripShareText.viewOnly(.current))

        // 여행을 지우면 이 기기에서 방을 잊는다(서버 처리는 묶음 A가 채운다).
        let allowed = await TripShareOwnerActions.tripWillDelete(model: model, tripID: "t1")
        XCTAssertTrue(allowed)
        XCTAssertFalse(model.isSharedTrip("t1"))
    }
}
