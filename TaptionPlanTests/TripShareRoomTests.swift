import XCTest
@testable import TaptionPlan
import TaptionPlanCore
import TaptionPlanStore
import TaptionTripShare
import TaptionTripShareTesting

/// 여행 공유 묶음 A(TSH1114A26): 방 만들기·올리기·입장·참여자·주인 동작·수명. 서버는 `ShareFakeServer`.
@MainActor
final class TripShareRoomTests: XCTestCase {
    private var originalStore: TripShareStore!
    private var originalNickname: String!
    private var folder: URL!
    private var stores: [TripShareStore] = []
    /// 시험용 유도 횟수(진짜는 60만 회).
    private let rounds = 20
    private let ownerPassword = "가을여행-2031"

    override func setUp() async throws {
        originalStore = TripShareStore.shared
        originalNickname = TripShareRoomWork.savedNickname
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TripShareRoomTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for store in stores { for link in store.links { await store.close(tripID: link.tripID) } }
        stores = []
        TripShareStore.shared = originalStore
        TripShareRoomWork.savedNickname = originalNickname
        TripShareInbox.shared.pending = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// 기기 하나(자기 키 보관·곁 파일)를 같은 서버에 붙인다. 시계는 가짜 서버의 시각에 맞춘다.
    private func device(_ server: ShareFakeServer, appKey: String? = "test-app-key") -> TripShareStore {
        var environment = TripShareEnvironment(
            transport: server.transport, secrets: TripShareMemorySecrets(),
            sidecar: TripShareSidecar(directory: folder.appendingPathComponent(UUID().uuidString, isDirectory: true)), appKey: { appKey }
        )
        environment.session = ShareSessionEnvironment(
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            sleep: { _, _ in try await Task.sleep(for: .milliseconds(30)) }
        )
        let store = TripShareStore(environment: environment)
        stores.append(store)
        return store
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private let trip = TravelTrip(id: "t1", title: "가을 여행", startDay: "2031-10-01", endDay: "2031-10-02")

    /// 여행 `t1`과 일정 `count`건을 넣는다. 첫 일정에는 좌표가 있는 핀을 붙인다.
    private func seed(_ model: AppModel, count: Int) async {
        let base = ISO8601DateFormatter().date(from: "2031-10-01T00:00:00Z")!
        let drafts = (0..<count).map { index in
            TripShareMapping.PlanDraft(item: TravelTripItem(
                tripID: "t1", itemID: "m-\(String(format: "%08d", index))", kind: "sight", title: "곳 \(index)",
                start: base.addingTimeInterval(Double(index) * 600), end: base.addingTimeInterval(Double(index) * 600 + 300),
                startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil
            ))
        }
        let added = await model.applySharedPlanChanges(tripID: "t1", upserts: drafts, trip: trip)
        XCTAssertTrue(added)
        model.snapshot.settings.travelPlanStops = [
            TravelPlanStop(id: UUID(), title: "전망대", latitude: 12.345678, longitude: 98.765432, day: base, order: 3, planID: nil, tripID: "t1", itemID: "m-00000000"),
        ]
    }

    private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("기다림이 끝나지 않음: \(what)")
    }

    /// 주인 기기에서 방을 만들고 다 올린다.
    private func shared(_ server: ShareFakeServer, model: AppModel) async throws -> (store: TripShareStore, invite: ShareInvite) {
        let store = device(server)
        let invite = try await TripShareCreation.create(store: store, trip: trip, password: ownerPassword, nickname: "가을", iterations: rounds)
        try await TripShareCreation.upload(model: model, store: store, tripID: "t1")
        return (store, invite)
    }

    private func joined(_ server: ShareFakeServer, _ invite: ShareInvite, nickname: String, password: String? = nil) async throws -> TripShareStore {
        let store = device(server)
        try await TripShareJoining.join(store: store, invite: invite, password: password ?? ownerPassword, nickname: nickname, iterations: rounds)
        return store
    }

    // MARK: 만들기·올리기

    func testCreateUploadsEveryPlanInBatchesWithoutCoordinates() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 60)
        let store = device(server)

        let invite = try await TripShareCreation.create(store: store, trip: trip, password: ownerPassword, nickname: "  가을  ", iterations: rounds)
        let link = try XCTUnwrap(store.link(tripID: "t1"))
        XCTAssertEqual(link.roomID, invite.roomID)
        XCTAssertEqual(link.role, .owner)
        XCTAssertEqual(link.phase, .uploading, "방을 만든 직후는 올리는 중")
        XCTAssertTrue(store.isShared("t1"))
        XCTAssertEqual(TripShareRoomWork.inviteURL(store: store, tripID: "t1"), TripShareEnvironment.inviteURL(invite))
        XCTAssertEqual(TripShareRoomWork.inviteURL(store: store, tripID: "t1")?.scheme, "taptionplan")

        try await TripShareCreation.upload(model: model, store: store, tripID: "t1")
        XCTAssertEqual(store.link(tripID: "t1")?.phase, .sharing)
        XCTAssertEqual(store.link(tripID: "t1")?.uploaded, [])
        let view = try XCTUnwrap(store.view(tripID: "t1"))
        XCTAssertEqual(view.items(of: .plan).count, 60, "한 번에 50건 한도를 넘어도 모두 올린다")
        XCTAssertEqual(view.meta?.name, "가을 여행")
        XCTAssertEqual(view.cards[1]?.name, "가을", "닉네임은 다듬어 올린다")
        XCTAssertTrue(view.items.allSatisfy { !$0.json.contains("12.345") && !$0.json.contains("98.765") && !$0.json.contains("latitude") }, "좌표는 올리지 않는다")
        let first = try XCTUnwrap(view.items.first { $0.id == TripShareMapping.roomItemID(tripID: "t1", itemID: "m-00000000") })
        guard case .plan(let plan) = first.content else { return XCTFail("일정이 아님") }
        XCTAssertEqual(plan.place, "전망대", "장소는 이름만")
        XCTAssertNotNil(first.group, "날 묶음 이름이 붙는다")

        // 다시 불러도 겹쳐 올리지 않는다.
        let rev = await server.rev(roomID: invite.roomID)
        try await TripShareCreation.upload(model: model, store: store, tripID: "t1")
        let after = await server.rev(roomID: invite.roomID)
        XCTAssertEqual(after, rev)
    }

    func testUploadResumesAfterTheConnectionDrops() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 12)
        let store = device(server)
        let invite = try await TripShareCreation.create(store: store, trip: trip, password: ownerPassword, nickname: "가을", iterations: rounds)

        await server.setOffline(true)
        do {
            try await TripShareCreation.upload(model: model, store: store, tripID: "t1")
            XCTFail("인터넷이 없으면 올리지 못한다")
        } catch {
            XCTAssertEqual(TripShareRoomText.message(error, .korean), TripShareRoomText.message(ShareError.offline, .korean))
        }
        XCTAssertEqual(store.link(tripID: "t1")?.phase, .uploading, "끊겨도 방과 연결은 남는다")
        XCTAssertFalse(TripShareCreation.uploading.contains("t1"))

        // 일부만 올라간 채 끊긴 것처럼: 앞의 5건을 방에 먼저 넣어 둔다.
        await server.setOffline(false)
        await waitUntil("다시 연결") { store.canEdit("t1") }
        let session = try XCTUnwrap(store.session(tripID: "t1"))
        let some = (model.settings.travelTripItems ?? []).prefix(5)
        _ = try await session.write(some.map { .create(id: TripShareMapping.roomItemID(tripID: "t1", itemID: $0.itemID), content: .plan(TripShareMapping.plan($0)), group: nil) })

        try await TripShareCreation.upload(model: model, store: store, tripID: "t1")
        XCTAssertEqual(store.link(tripID: "t1")?.phase, .sharing)
        XCTAssertEqual(store.view(tripID: "t1")?.items(of: .plan).count, 12, "이미 있는 것은 건너뛰고 나머지를 올린다")
        XCTAssertNotNil(store.view(tripID: "t1")?.meta)
        _ = invite
    }

    func testCreateChecksPasswordNicknameAndRegistration() async throws {
        let server = ShareFakeServer()
        let store = device(server)
        await XCTAssertThrowsRoomError(.passwordTooShort(minimum: 6)) {
            _ = try await TripShareCreation.create(store: store, trip: self.trip, password: "12345", nickname: "가을", iterations: self.rounds)
        }
        await XCTAssertThrowsRoomError(.nicknameEmpty) {
            _ = try await TripShareCreation.create(store: store, trip: self.trip, password: self.ownerPassword, nickname: "   ", iterations: self.rounds)
        }
        let unregistered = device(server, appKey: nil)
        await XCTAssertThrowsRoomError(.notRegistered) {
            _ = try await TripShareCreation.create(store: unregistered, trip: self.trip, password: self.ownerPassword, nickname: "가을", iterations: self.rounds)
        }
        XCTAssertNil(store.link(tripID: "t1"))
        XCTAssertNil(unregistered.link(tripID: "t1"))
        let calls = await server.calls
        XCTAssertTrue(calls.isEmpty, "막힌 만들기는 서버에 가지 않는다")
    }

    func testRoomExpiryFollowsTheTripEndWithinServerLimits() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let day = 86_400_000
        let nowMillis = 1_900_000_000_000
        let undated = TravelTrip(id: "w", title: "언젠가", startDay: "", endDay: "")
        XCTAssertEqual(TripShareCreation.expiry(trip: undated, now: now), nowMillis + 90 * day)
        let far = TripShareCreation.expiry(trip: trip, now: now)
        XCTAssertEqual(far, nowMillis + 399 * day, "먼 여행은 서버 상한 안으로")
        let past = TravelTrip(id: "p", title: "지난 여행", startDay: "2029-01-01", endDay: "2029-01-02")
        XCTAssertEqual(TripShareCreation.expiry(trip: past, now: now), nowMillis + 7 * day)
        let soon = TravelTrip(id: "s", title: "곧", startDay: "2030-04-01", endDay: "2030-04-03")
        let expected = Int(ISO8601DateFormatter().date(from: "2030-05-04T00:00:00Z")!.timeIntervalSince1970 * 1000)
        XCTAssertEqual(TripShareCreation.expiry(trip: soon, now: now), expected, "여행 끝 + 30일의 끝")
    }

    // MARK: 입장·참여자

    func testJoinAddsTheMemberAndPublishesACard() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 3)
        let (owner, invite) = try await shared(server, model: model)

        let guest = try await joined(server, invite, nickname: "단풍")
        let tripID = TripShareMapping.joinedTripID(roomID: invite.roomID)
        let link = try XCTUnwrap(guest.link(tripID: tripID))
        XCTAssertEqual(link.role, .member)
        XCTAssertEqual(link.phase, .sharing)
        XCTAssertEqual(guest.view(tripID: tripID)?.items(of: .plan).count, 3, "들어오면 방의 일정을 받는다")
        XCTAssertEqual(guest.view(tripID: tripID)?.me, 2)
        XCTAssertNil(try guest.environment.secrets.secrets(roomID: invite.roomID)?.ownerKey, "참여자에게는 주인 열쇠가 없다")
        XCTAssertFalse(TripShareCreation.canCreate(store: guest, tripID: tripID), "참여한 여행은 다시 공유하지 못한다")

        await waitUntil("주인이 새 사람과 카드를 봄") { owner.view(tripID: "t1")?.cards[2]?.name == "단풍" && owner.memberCount(tripID: "t1") == 2 }
        XCTAssertEqual(owner.names(tripID: "t1")?.name(.member(2)), "단풍")

        await XCTAssertThrowsRoomError(.alreadyJoined) {
            try await TripShareJoining.join(store: guest, invite: invite, password: self.ownerPassword, nickname: "단풍", iterations: self.rounds)
        }
    }

    /// 입장 직후 끊겨 카드를 못 올린 기기: 방을 다시 열면 연결을 기다려 카드를 올린다(TSA1117A01).
    func testAMissingCardIsPublishedOnceTheRoomIsLive() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 1)
        let (owner, invite) = try await shared(server, model: model)
        let keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: ownerPassword, iterations: rounds)
        let entry = try await ShareRoomClient.join(transport: server.transport, roomID: invite.roomID, proof: keys.proof)
        let guest = device(server)
        let tripID = TripShareMapping.joinedTripID(roomID: invite.roomID)
        try guest.register(
            TripShareLink(roomID: invite.roomID, tripID: tripID, role: .member, phase: .sharing),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, member: entry.member, epoch: entry.epoch)
        )
        TripShareRoomWork.savedNickname = "단풍"

        await TripShareRoomWork.ensureCard(store: guest, tripID: tripID)
        XCTAssertEqual(guest.view(tripID: tripID)?.cards[entry.member]?.name, "단풍", "연결을 기다린 뒤 카드를 올린다")
        await waitUntil("주인이 카드를 봄") { owner.names(tripID: "t1")?.name(.member(entry.member)) == "단풍" }

        // 이미 카드가 있으면 다시 올리지 않는다.
        let rev = await server.rev(roomID: invite.roomID)
        await TripShareRoomWork.ensureCard(store: guest, tripID: tripID)
        let after = await server.rev(roomID: invite.roomID)
        XCTAssertEqual(after, rev)
    }

    func testJoinFailuresHaveTheirOwnMessagesAndLeaveNothingBehind() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 1)
        let (_, invite) = try await shared(server, model: model)

        let stranger = device(server)
        do {
            try await TripShareJoining.join(store: stranger, invite: invite, password: "틀린-비밀번호", nickname: "손님", iterations: rounds)
            XCTFail("틀린 비밀번호로는 못 들어온다")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .wrongPassword)
            XCTAssertTrue(TripShareRoomText.message(error, .korean).contains("4번"), "남은 횟수를 알린다")
        }
        XCTAssertEqual(stranger.links, [])
        XCTAssertNil(try stranger.environment.secrets.secrets(roomID: invite.roomID))

        let missing = ShareInvite.make()
        do {
            try await TripShareJoining.join(store: stranger, invite: missing, password: ownerPassword, nickname: "손님", iterations: rounds)
            XCTFail("없는 방")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .notFound)
        }

        // 10명이 차면 열한 번째는 못 들어온다.
        let keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: ownerPassword, iterations: rounds)
        for _ in 2...10 { _ = try await ShareRoomClient.join(transport: server.transport, roomID: invite.roomID, proof: keys.proof) }
        do {
            try await TripShareJoining.join(store: stranger, invite: invite, password: ownerPassword, nickname: "손님", iterations: rounds)
            XCTFail("가득 찬 방")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .roomFull)
            XCTAssertTrue(TripShareRoomText.message(error, .korean).contains("10명"))
        }
        XCTAssertEqual(stranger.links, [])

        var locked = ShareErrorDetail(error: "join_locked")
        locked.retryAfter = 130
        XCTAssertTrue(TripShareRoomText.message(ShareError.server(ShareServerError(status: 429, detail: locked)), .korean).contains("3분"), "기다릴 시간을 분으로 올려 알린다")
        XCTAssertNotEqual(
            TripShareRoomText.message(ShareError.server(ShareServerError(status: 404, detail: ShareErrorDetail(error: "not_found"))), .korean),
            TripShareRoomText.message(ShareError.server(ShareServerError(status: 409, detail: ShareErrorDetail(error: "room_full"))), .korean)
        )
        XCTAssertNil(TripShareEnvironment.invite(from: "https://example.invalid/share#\(invite.fragment)"), "앱 스킴 링크만 받는다")
    }

    // MARK: 주인 동작·수명

    func testKickEndsTheMemberButKeepsTheirLocalLinkAsEnded() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 2)
        let (owner, invite) = try await shared(server, model: model)
        let guest = try await joined(server, invite, nickname: "단풍")
        let guestTrip = TripShareMapping.joinedTripID(roomID: invite.roomID)

        let recommended = try await TripShareOwnerActions.kick(store: owner, tripID: "t1", member: 2)
        XCTAssertTrue(recommended, "내보낸 뒤에는 비밀번호 바꾸기를 권한다")
        await waitUntil("내보내진 기기가 끝남을 앎") { guest.link(tripID: guestTrip)?.phase == .ended }
        XCTAssertFalse(guest.isShared(guestTrip), "끝난 방의 여행은 보통 여행")
        XCTAssertEqual(guest.view(tripID: guestTrip)?.status, .ended(.kicked))
        XCTAssertEqual(guest.view(tripID: guestTrip)?.items(of: .plan).count, 2, "로컬 사본은 남는다")
        await waitUntil("주인 쪽 사람 수") { owner.memberCount(tripID: "t1") == 1 }

        do {
            _ = try await TripShareOwnerActions.kick(store: guest, tripID: guestTrip, member: 1)
            XCTFail("끝난 방에서는 아무것도 못 한다")
        } catch {}
    }

    func testPasswordChangeRotatesKeysAndMembersReprove() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 4)
        let (owner, invite) = try await shared(server, model: model)
        let guest = try await joined(server, invite, nickname: "단풍")
        let guestTrip = TripShareMapping.joinedTripID(roomID: invite.roomID)
        let oldRoot = try XCTUnwrap(try owner.environment.secrets.secrets(roomID: invite.roomID)).root

        await XCTAssertThrowsRoomError(.passwordTooShort(minimum: 6)) {
            _ = try await TripShareOwnerActions.changePassword(store: owner, tripID: "t1", password: "짧다", iterations: self.rounds)
        }
        let newPassword = "겨울여행-2032"
        let change = try await TripShareOwnerActions.changePassword(store: owner, tripID: "t1", password: newPassword, iterations: rounds)
        XCTAssertEqual(change, .done)
        let ownerSecrets = try XCTUnwrap(try owner.environment.secrets.secrets(roomID: invite.roomID))
        XCTAssertNotEqual(ownerSecrets.root, oldRoot)
        XCTAssertEqual(ownerSecrets.epoch, 2)
        XCTAssertNotNil(ownerSecrets.ownerKey)
        XCTAssertEqual(ownerSecrets.linkSecret, invite.linkSecret, "초대 링크는 그대로")
        XCTAssertEqual(owner.view(tripID: "t1")?.items(of: .plan).count, 4)
        XCTAssertEqual(owner.view(tripID: "t1")?.unreadable, [])
        XCTAssertTrue(owner.canEdit("t1"))

        await waitUntil("참여자가 비밀번호 바뀜을 앎") { guest.view(tripID: guestTrip)?.status == .needsRekey }
        XCTAssertFalse(guest.canEdit(guestTrip), "새 비밀번호를 넣을 때까지 보기만")
        do {
            try await TripShareRoomWork.rekey(store: guest, tripID: guestTrip, password: ownerPassword, iterations: rounds)
            XCTFail("옛 비밀번호로는 다시 증명하지 못한다")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .wrongPassword)
        }
        try await TripShareRoomWork.rekey(store: guest, tripID: guestTrip, password: newPassword, iterations: rounds)
        await waitUntil("참여자가 다시 맞춰짐") { guest.canEdit(guestTrip) && guest.view(tripID: guestTrip)?.items(of: .plan).count == 4 }
        let guestSecrets = try XCTUnwrap(try guest.environment.secrets.secrets(roomID: invite.roomID))
        XCTAssertEqual(guestSecrets.root, ownerSecrets.root)
        XCTAssertEqual(guestSecrets.epoch, 2)
        XCTAssertEqual(guest.view(tripID: guestTrip)?.meta?.name, "가을 여행", "새 키로 처음부터 다시 받아 읽는다")

        // 옛 비밀번호로는 새로 들어오지 못한다.
        do {
            _ = try await joined(server, invite, nickname: "옛 손님")
            XCTFail("옛 비밀번호")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .wrongPassword)
        }
    }

    func testMemberLeavesAndOwnerDeletesTheRoom() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 2)
        let (owner, invite) = try await shared(server, model: model)
        let guest = try await joined(server, invite, nickname: "단풍")
        let other = try await joined(server, invite, nickname: "은행")
        let guestTrip = TripShareMapping.joinedTripID(roomID: invite.roomID)

        do {
            try await TripShareOwnerActions.leave(store: owner, tripID: "t1")
            XCTFail("주인은 나가지 못한다")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .ownerCannotLeave)
        }
        XCTAssertTrue(owner.isShared("t1"))

        try await TripShareOwnerActions.leave(store: guest, tripID: guestTrip)
        XCTAssertNil(guest.link(tripID: guestTrip), "나가면 이 기기에서 방을 잊는다")
        XCTAssertNil(try guest.environment.secrets.secrets(roomID: invite.roomID))
        XCTAssertEqual(guest.environment.sidecar.links(), [])
        XCTAssertFalse(TripShareCreation.canCreate(store: guest, tripID: guestTrip), "나간 뒤에도 받은 여행은 다시 공유하지 못한다")
        await waitUntil("주인 쪽 사람 수") { owner.memberCount(tripID: "t1") == 2 }

        try await TripShareOwnerActions.deleteRoom(store: owner, tripID: "t1")
        XCTAssertNil(owner.link(tripID: "t1"))
        XCTAssertNil(try owner.environment.secrets.secrets(roomID: invite.roomID))
        XCTAssertFalse(owner.isShared("t1"))
        XCTAssertEqual(model.settings.travelTripItems?.count, 2, "로컬 여행은 그대로")
        XCTAssertTrue(TripShareCreation.canCreate(store: owner, tripID: "t1"), "주인은 다시 공유를 만들 수 있다")

        await waitUntil("남은 참여자가 방이 사라짐을 앎") { other.link(tripID: guestTrip)?.phase == .ended }
        XCTAssertEqual(other.view(tripID: guestTrip)?.status, .ended(.gone))
        XCTAssertFalse(TripShareRoomText.ended(.gone, .korean).isEmpty)
        do {
            _ = try await joined(server, invite, nickname: "늦은 손님")
            XCTFail("지운 방")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .notFound)
        }
    }

    func testDeletingASharedTripEndsTheRoomOrAsksOnceWhenOffline() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 2)
        let (owner, invite) = try await shared(server, model: model)
        TripShareStore.shared = owner

        await server.setOffline(true)
        await waitUntil("끊김을 앎") { owner.view(tripID: "t1")?.status == .offline }
        let first = await model.deleteTravelTrip("t1")
        XCTAssertFalse(first, "서버에 닿지 못하면 한 번은 지우지 않고 알린다")
        XCTAssertNotNil(model.userFacingError)
        XCTAssertTrue(owner.isShared("t1"))
        XCTAssertEqual(model.settings.travelTrips?.map(\.id), ["t1"])

        await server.setOffline(false)
        await waitUntil("다시 연결") { owner.canEdit("t1") }
        model.userFacingError = nil
        let second = await model.deleteTravelTrip("t1")
        XCTAssertTrue(second)
        XCTAssertNil(owner.link(tripID: "t1"))
        XCTAssertNil(model.settings.travelTrips?.first { $0.id == "t1" })
        do {
            _ = try await joined(server, invite, nickname: "손님")
            XCTFail("여행을 지우면 방도 지워진다")
        } catch {
            XCTAssertEqual((error as? ShareError)?.serverCode, .notFound)
        }
    }

    func testDeletingTwiceWhileOfflineForgetsOnThisDeviceOnly() async throws {
        let server = ShareFakeServer()
        let model = await makeModel()
        await seed(model, count: 1)
        let (owner, _) = try await shared(server, model: model)
        TripShareStore.shared = owner
        await server.setOffline(true)
        await waitUntil("끊김을 앎") { owner.view(tripID: "t1")?.status == .offline }

        let first = await TripShareOwnerActions.tripWillDelete(model: model, tripID: "t1")
        XCTAssertFalse(first)
        let second = await TripShareOwnerActions.tripWillDelete(model: model, tripID: "t1")
        XCTAssertTrue(second, "두 번째에는 이 기기에서만 잊는다")
        XCTAssertNil(owner.link(tripID: "t1"))
        let untouched = await TripShareOwnerActions.tripWillDelete(model: model, tripID: "t2")
        XCTAssertTrue(untouched, "공유하지 않는 여행은 늘 지운다")
    }

    func testOnlyUnsharedOwnTripsOfferCreate() async throws {
        let server = ShareFakeServer()
        let store = device(server)
        XCTAssertTrue(TripShareCreation.canCreate(store: store, tripID: "t1"))
        let roomID = ShareIdentifiers.roomID()
        XCTAssertFalse(TripShareCreation.canCreate(store: store, tripID: TripShareMapping.joinedTripID(roomID: roomID)))
        XCTAssertTrue(TripShareCreation.canCreate(store: store, tripID: "s-short"), "방 번호 모양이 아니면 보통 여행")
        try store.save(TripShareLink(roomID: roomID, tripID: "t1", role: .owner, phase: .sharing))
        XCTAssertFalse(TripShareCreation.canCreate(store: store, tripID: "t1"), "이미 공유 중")
        try store.save(TripShareLink(roomID: roomID, tripID: "t1", role: .owner, phase: .ended))
        XCTAssertTrue(TripShareCreation.canCreate(store: store, tripID: "t1"), "끝난 내 방은 다시 만들 수 있다")
        let unavailable = TripShareStore(environment: TripShareEnvironment(
            transport: nil, secrets: TripShareMemorySecrets(), sidecar: TripShareSidecar(directory: folder.appendingPathComponent("none")), appKey: { nil }
        ))
        XCTAssertFalse(TripShareCreation.canCreate(store: unavailable, tripID: "t1"))
    }

    private func XCTAssertThrowsRoomError(
        _ expected: TripShareRoomError, file: StaticString = #filePath, line: UInt = #line, _ work: @MainActor () async throws -> Void
    ) async {
        do {
            try await work()
            XCTFail("실패해야 함", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TripShareRoomError, expected, file: file, line: line)
        }
    }
}
