import XCTest
@testable import TaptionPlan
import TaptionPlanCore
import TaptionPlanStore
import TaptionTripShare
import TaptionTripShareTesting

/// 여행 공유 묶음 B(TSH1114A26): 계획 공동 편집. 가짜 서버에 이 앱(창구 + 앱 모델)과 다른 참여자(세션만)를 함께 붙여 본다.
@MainActor
final class TripSharePlanTests: XCTestCase {
    private struct Shared {
        let server: ShareFakeServer
        let roomID: String
        let tripID: String
        let model: AppModel
        /// 이 앱이 아닌 다른 참여자.
        let other: ShareRoomSession
    }

    private var originalStore: TripShareStore!
    private var folder: URL!
    private var sessions: [ShareRoomSession] = []
    private var openTrips: [String] = []

    private var store: TripShareStore { .shared }

    override func setUp() async throws {
        originalStore = TripShareStore.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TripSharePlanTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for tripID in openTrips { await TripShareStore.shared.close(tripID: tripID) }
        for session in sessions { await session.stop() }
        (sessions, openTrips) = ([], [])
        TripShareStore.shared = originalStore
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: 준비

    private func stamp(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func eventually(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("기다렸지만 되지 않음: \(what)", file: file, line: line)
    }

    private func makeModel(_ repository: any PlanDataRepository = InMemoryPlanRepository(snapshot: .empty)) async -> AppModel {
        let model = AppModel(repository: repository, cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func item(_ model: AppModel, _ itemID: String) -> TravelTripItem? {
        (model.settings.travelTripItems ?? []).first { $0.itemID == itemID }
    }

    private func plan(_ session: ShareRoomSession, _ id: String) async -> SharePlanContent? {
        guard case .plan(let content)? = await session.item(id)?.content else { return nil }
        return content
    }

    /// 방 하나에 이 앱과 다른 참여자가 함께 들어가 있는 상태를 만든다.
    /// - Parameter appIsOwner: true면 이 앱이 방을 만든 주인(참여자 1), false면 이 앱이 초대로 들어온 참여자(2).
    private func share(
        appIsOwner: Bool = true, repository: any PlanDataRepository = InMemoryPlanRepository(snapshot: .empty),
        session environment: ShareSessionEnvironment = ShareSessionEnvironment()
    ) async throws -> Shared {
        let server = ShareFakeServer()
        var appEnvironment = TripShareEnvironment(
            transport: server.transport, secrets: TripShareMemorySecrets(), sidecar: TripShareSidecar(directory: folder), appKey: { "test-app-key" }
        )
        appEnvironment.session = environment
        TripShareStore.shared = TripShareStore(environment: appEnvironment)
        let invite = ShareInvite.make()
        let keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: "가을여행-2031", iterations: 20)
        let ownerKey = ShareIdentifiers.ownerKey()
        let owner = try await ShareRoomClient.createRoom(
            transport: server.transport, appKey: "test-app-key",
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 86_400_000)
        )
        let member = try await ShareRoomClient.join(transport: server.transport, roomID: invite.roomID, proof: keys.proof)
        let mine = appIsOwner ? owner : member, theirs = appIsOwner ? member : owner
        let tripID = appIsOwner ? "t1" : TripShareMapping.joinedTripID(roomID: invite.roomID)
        let trip = TravelTrip(id: tripID, title: "가을 여행", startDay: "2031-10-01", endDay: "2031-10-02")

        let other = ShareRoomSession(
            roomID: invite.roomID, member: theirs.member, epoch: theirs.epoch, keys: keys,
            client: ShareRoomClient(transport: server.transport, roomID: invite.roomID, token: theirs.token, ownerKey: appIsOwner ? nil : ownerKey)
        )
        sessions.append(other)
        await other.start()
        await eventually("다른 참여자 연결") { await other.view().status == .live }
        _ = try await other.publish(card: ShareMemberCard(name: "겨울", color: "#334455"))
        if !appIsOwner { _ = try await other.publish(meta: TripShareMapping.meta(trip)) }

        let model = await makeModel(repository)
        if appIsOwner {
            let saved = await model.saveTravelTrip(trip)
            XCTAssertTrue(saved)
        }
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: tripID, role: appIsOwner ? .owner : .member, phase: .sharing),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: mine.token, ownerKey: appIsOwner ? ownerKey : nil, member: mine.member, epoch: mine.epoch)
        )
        store.attach(model)
        openTrips.append(tripID)
        let opened = await store.open(tripID: tripID)
        let session = try XCTUnwrap(opened)
        await eventually("이 앱 연결") { self.store.canEdit(tripID) }
        try await session.catchUp()
        _ = try await session.publish(card: ShareMemberCard(name: "가을", color: "#112233"))
        if appIsOwner { _ = try await session.publish(meta: TripShareMapping.meta(trip)) }
        await eventually("서로의 이름표") { self.store.names(tripID: tripID)?.name(.member(theirs.member)) == "겨울" }
        return Shared(server: server, roomID: invite.roomID, tripID: tripID, model: model, other: other)
    }

    private func add(_ shared: Shared, _ title: String, _ start: String, _ end: String, parent: String? = nil, place: TravelItemPlace? = nil) async throws -> String {
        let added = await TripSharePlanEditor.addItem(
            model: shared.model, tripID: shared.tripID, kind: .sight, title: title, start: stamp(start), end: stamp(end), offsetSeconds: 32_400,
            place: place, parentItemID: parent
        )
        return try XCTUnwrap(added)
    }

    // MARK: 넣기·고치기·옮기기·지우기가 오간다

    func testAddUpdateMoveAndDeleteTravelBothWays() async throws {
        let shared = try await share()
        let model = shared.model, other = shared.other

        // 이 앱이 넣는다: 방에 올라가고 로컬에는 일상 계획과 이 기기의 핀이 생긴다. 방에는 장소 이름만 간다.
        let itemID = try await add(shared, "성 구경", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z", place: TravelItemPlace(name: "성", latitude: 1.25, longitude: 2.5))
        let local = try XCTUnwrap(item(model, itemID))
        XCTAssertTrue(model.snapshot.plans.contains { $0.id == local.planID })
        XCTAssertEqual(model.settings.travelPlanStops.map(\.latitude), [1.25])
        await eventually("넣은 일정이 다른 참여자에게") { await other.item(itemID) != nil }
        // 일상 시간표에서는 이 계획 기록을 옮기거나 지우지 못한다(TSF1115A01). 아래의 여행 화면 편집은 그대로 된다.
        let linkedPlanID = try XCTUnwrap(local.planID)
        model.movePlan(linkedPlanID, by: 1_800)
        await model.deletePlan(linkedPlanID)
        XCTAssertEqual(model.userFacingError, TripShareText.editBlocked(.current))
        XCTAssertEqual(model.snapshot.plans.first { $0.id == linkedPlanID }?.span.start, stamp("2031-10-01T01:00:00Z"))
        model.userFacingError = nil
        let sentPlan = await plan(other, itemID)
        let sent = try XCTUnwrap(sentPlan)
        XCTAssertEqual([sent.title, sent.place, sent.day], ["성 구경", "성", "2031-10-01"])
        XCTAssertEqual([sent.start, sent.end], [600, 660])
        let remoteItem = await other.item(itemID)
        let remote = try XCTUnwrap(remoteItem)
        XCTAssertNotNil(remote.group, "날 묶음 이름이 붙는다")
        XCTAssertFalse(remote.json.contains("1.25") || remote.json.contains("2.5") || remote.json.lowercased().contains("lat"), "좌표는 방에 올리지 않는다")

        // 다른 참여자가 고친다: 이 앱의 일정·일상 계획이 따라가고, 이 기기의 핀과 계획 연결은 남는다.
        var edited = sent
        (edited.title, edited.start, edited.end, edited.place) = ("성 구경(오후)", 660, 720, "성 뒤뜰")
        try await other.lock(items: [itemID])
        _ = try await other.write([.update(id: itemID, content: .plan(edited))])
        try await other.unlock(items: [itemID])
        await eventually("남의 고침이 로컬에") { self.item(model, itemID)?.title == "성 구경(오후)" }
        let updated = try XCTUnwrap(item(model, itemID))
        XCTAssertEqual(updated.start, stamp("2031-10-01T02:00:00Z"))
        XCTAssertEqual(updated.planID, local.planID)
        XCTAssertEqual(model.snapshot.plans.first { $0.id == local.planID }?.title, "성 구경(오후)")
        XCTAssertEqual(model.settings.travelPlanStops.map(\.latitude), [1.25])
        XCTAssertEqual(TripSharePlanEditor.placeName(tripID: shared.tripID, itemID: itemID), "성 뒤뜰", "장소 이름은 방 사본에서 읽는다")

        // 이 앱이 코스 곳을 옮기면 딸린 세부 계획도 함께 옮겨진다.
        let detailID = try await add(shared, "표 사기", "2031-10-01T02:10:00Z", "2031-10-01T02:20:00Z", parent: itemID)
        let moved = await TripSharePlanEditor.moveItem(model: model, tripID: shared.tripID, itemID: itemID, by: 1_800)
        XCTAssertTrue(moved)
        XCTAssertEqual(item(model, itemID)?.start, stamp("2031-10-01T02:30:00Z"))
        XCTAssertEqual(item(model, detailID)?.start, stamp("2031-10-01T02:40:00Z"))
        await eventually("옮긴 것이 다른 참여자에게") {
            let (parent, detail) = (await self.plan(other, itemID), await self.plan(other, detailID))
            return parent?.start == 690 && detail?.start == 700 && detail?.parentItemID == itemID && parent?.place == "성 뒤뜰"
        }
        let resized = await TripSharePlanEditor.resizeItem(model: model, tripID: shared.tripID, itemID: itemID, endDelta: 600)
        XCTAssertTrue(resized)
        await eventually("길이 바꾼 것이 다른 참여자에게") { await self.plan(other, itemID)?.end == 760 }

        // 이 앱이 지우면 세부까지 방에서 사라지고, 로컬의 일상 계획·핀도 사라진다.
        let step = await TripSharePlanEditor.deleteItem(model: model, tripID: shared.tripID, itemID: itemID)
        XCTAssertEqual(step?.group.count, 2)
        XCTAssertNil(model.settings.travelTripItems)
        XCTAssertEqual(model.snapshot.plans.count, 0)
        XCTAssertEqual(model.settings.travelPlanStops, [])
        await eventually("지운 것이 다른 참여자에게") { await other.view().items(of: .plan).isEmpty }

        // 다른 참여자가 넣고 지운다.
        let theirs = ShareIdentifiers.itemID()
        _ = try await other.write([.create(id: theirs, content: .plan(SharePlanContent(day: "2031-10-02", start: 540, end: 600, startOffset: 540, endOffset: 540, title: "시장", place: "시장 입구", planKind: "meal")), group: nil)])
        await eventually("남이 넣은 일정이 로컬에") { self.item(model, theirs) != nil }
        XCTAssertEqual(item(model, theirs)?.kind, "meal")
        XCTAssertEqual(model.settings.travelPlanStops, [], "이름뿐인 장소로 핀을 만들지 않는다")
        XCTAssertEqual(TripSharePlanEditor.placeName(tripID: shared.tripID, itemID: theirs), "시장 입구")
        try await other.lock(items: [theirs])
        _ = try await other.write([.delete(id: theirs)])
        await eventually("남이 지운 일정이 로컬에서도") { self.item(model, theirs) == nil }
        XCTAssertEqual(model.snapshot.plans.count, 0, "딸린 일상 계획도 지운다")
    }

    func testManyRemoteChangesAreSavedOnce() async throws {
        let repository = PermissionCountingPlanRepository()
        let shared = try await share(repository: repository)
        let ids = (0..<5).map { _ in ShareIdentifiers.itemID() }
        let before = await repository.saveCount
        _ = try await shared.other.write(ids.enumerated().map { index, id in
            .create(id: id, content: .plan(SharePlanContent(day: "2031-10-01", start: 540 + index * 60, end: 590 + index * 60, startOffset: 540, endOffset: 540, title: "곳 \(index)")), group: nil)
        })
        await eventually("다섯 건이 로컬에") { (shared.model.settings.travelTripItems ?? []).count == 5 }
        // 뒤따르는 알림이 더 저장하지 않는지 잠깐 본다.
        try await Task.sleep(for: .milliseconds(200))
        let after = await repository.saveCount
        XCTAssertEqual(after - before, 1, "한 번에 온 여러 변경은 저장 한 번")
        XCTAssertEqual(shared.model.snapshot.plans.count, 5)
    }

    // MARK: 잠금

    func testALockedCellCannotBeEditedUntilItIsReleased() async throws {
        let shared = try await share()
        let model = shared.model, other = shared.other, tripID = shared.tripID
        let itemID = try await add(shared, "성 구경", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z")
        await eventually("일정이 다른 참여자에게") { await other.item(itemID) != nil }

        // 다른 참여자가 그 칸을 잡는다: 배지가 뜨고, 이 앱에서는 열기·옮기기·지우기가 막힌다.
        try await other.lock(items: [itemID])
        await eventually("남의 잠금이 보임") { if case .other(by: 2, _) = self.store.lockState(tripID: tripID, itemID: itemID) { true } else { false } }
        var ran = 0
        for edit in [TripSharePlanEdit.open(itemID: itemID), .move(itemID: itemID, minutes: 30), .resize(itemID: itemID, minutes: 30), .delete(itemID: itemID)] {
            store.notice = nil
            TripSharePlanEditor.route(model: model, tripID: tripID, edit: edit) { ran += 1 }
            XCTAssertEqual(store.notice, TripSharePlanText.lockedBy("겨울", .current))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ran, 0, "잠긴 칸은 편집기를 열지 않는다")
        // 문지기를 건너뛰어도 방이 거절하고 로컬은 그대로다.
        store.notice = nil
        let forced = await TripSharePlanEditor.updateItem(
            model: model, tripID: tripID, itemID: itemID, kind: .sight, title: "몰래 고침", start: stamp("2031-10-01T03:00:00Z"), end: stamp("2031-10-01T04:00:00Z")
        )
        XCTAssertFalse(forced)
        XCTAssertEqual(store.notice, TripSharePlanText.lockedBy("겨울", .current))
        XCTAssertEqual(item(model, itemID)?.title, "성 구경")
        let untouched = await plan(other, itemID)
        XCTAssertEqual(untouched?.title, "성 구경")
        let blockedDelete = await TripSharePlanEditor.deleteItem(model: model, tripID: tripID, itemID: itemID)
        XCTAssertNil(blockedDelete)
        XCTAssertNotNil(item(model, itemID))
        // 새 일정 넣기는 남의 칸 잠금과 상관없다.
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .add(dayKey: "2031-10-01", parentItemID: nil)) { ran += 1 }
        XCTAssertEqual(ran, 1)

        // 풀리면 이 앱이 잡고 편집기를 연다. 그 동안 다른 참여자는 잡지도 고치지도 못한다.
        try await other.unlock(items: [itemID])
        await eventually("잠금이 풀림") { self.store.lockState(tripID: tripID, itemID: itemID) == .free }
        store.notice = nil
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .open(itemID: itemID)) { ran += 1 }
        await eventually("잠금을 잡고 편집기를 엶") { ran == 2 }
        XCTAssertNil(store.notice)
        if case .mine = store.lockState(tripID: tripID, itemID: itemID) {} else { XCTFail("이 앱이 잡고 있어야 한다") }
        await eventually("내 잠금이 다른 참여자에게 보임") { if case .other(by: 1, _) = await other.lockState(item: itemID) { true } else { false } }
        do {
            try await other.lock(items: [itemID])
            XCTFail("남이 잡은 칸은 잡히지 않는다")
        } catch let error as ShareError {
            XCTAssertEqual(error.serverCode, .locked)
        }
        let current = await plan(other, itemID)
        var sneaky = try XCTUnwrap(current)
        sneaky.title = "끼어들기"
        do {
            _ = try await other.write([.update(id: itemID, content: .plan(sneaky))])
            XCTFail("잠금 없이 고칠 수 없다")
        } catch let error as ShareError {
            XCTAssertTrue([.locked, .lockRequired].contains(error.serverCode))
        }

        // 편집기에서 저장: 잡아 둔 잠금으로 쓰고, 편집기가 닫힐 때 푼다.
        let saved = await TripSharePlanEditor.updateItem(
            model: model, tripID: tripID, itemID: itemID, kind: .meal, title: "성 앞 점심", start: stamp("2031-10-01T03:00:00Z"), end: stamp("2031-10-01T04:00:00Z"), note: "예약"
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(item(model, itemID)?.note, "예약")
        if case .mine = store.lockState(tripID: tripID, itemID: itemID) {} else { XCTFail("저장만으로는 편집기의 잠금을 풀지 않는다") }
        await eventually("고친 것이 다른 참여자에게") {
            let content = await self.plan(other, itemID)
            return content?.title == "성 앞 점심" && content?.planKind == "meal" && content?.start == 720
        }
        TripSharePlanEditor.endEditing(item(model, itemID))
        await eventually("편집기를 닫으면 풀림") { self.store.lockState(tripID: tripID, itemID: itemID) == .free }
        await eventually("다른 참여자도 풀린 것을 봄") { await other.lockState(item: itemID) == .free }
        try await other.lock(items: [itemID])
    }

    // MARK: 순서 바꾸기

    func testReorderIsAllOrNothing() async throws {
        let shared = try await share()
        let model = shared.model, other = shared.other, tripID = shared.tripID
        let first = try await add(shared, "성", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z")
        let second = try await add(shared, "시장", "2031-10-01T02:00:00Z", "2031-10-01T03:00:00Z")
        let third = try await add(shared, "전망대", "2031-10-01T03:00:00Z", "2031-10-01T04:00:00Z")
        await eventually("세 일정이 다른 참여자에게") { await other.view().items(of: .plan).count == 3 }
        // 첫째를 맨 뒤로: 둘째·셋째가 한 시간 앞으로, 첫째가 두 시간 뒤로.
        let step = try XCTUnwrap(TravelPlanHistory.Step.reorder(tripID: tripID, moves: [first: 120, second: -60, third: -60], title: "성"))

        // 그날의 한 칸을 남이 고치는 중이면 하나도 바뀌지 않는다.
        try await other.lock(items: [third])
        await eventually("남의 잠금이 보임") { self.store.lockState(tripID: tripID, itemID: third) != .free }
        let revision = await shared.server.rev(roomID: shared.roomID)
        store.notice = nil
        let refused = await TripSharePlanEditor.applyStep(model: model, step)
        XCTAssertFalse(refused)
        XCTAssertEqual(store.notice, TripSharePlanText.lockedBy("겨울", .current))
        XCTAssertEqual([first, second, third].map { item(model, $0)?.start }, ["2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z", "2031-10-01T03:00:00Z"].map(stamp))
        let unchanged = await shared.server.rev(roomID: shared.roomID)
        XCTAssertEqual(unchanged, revision, "방에도 쓰이지 않았다")
        await eventually("실패하면 잡은 잠금을 남기지 않는다") { await other.lockState(item: first) == .free }

        // 풀리면 셋이 한 번에 바뀌고, 잡았던 잠금(날 묶음 포함)은 모두 풀린다.
        try await other.unlock(items: [third])
        await eventually("잠금이 풀림") { self.store.lockState(tripID: tripID, itemID: third) == .free }
        store.notice = nil
        let done = await TripSharePlanEditor.applyStep(model: model, step)
        XCTAssertTrue(done)
        XCTAssertNil(store.notice)
        XCTAssertEqual([first, second, third].map { item(model, $0)?.start }, ["2031-10-01T03:00:00Z", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z"].map(stamp))
        await eventually("바뀐 순서가 다른 참여자에게") {
            let starts = [await self.plan(other, first)?.start, await self.plan(other, second)?.start, await self.plan(other, third)?.start]
            return starts == [720, 600, 660]
        }
        let after = await shared.server.rev(roomID: shared.roomID)
        XCTAssertEqual(after - revision, 3)
        await eventually("잠금이 남지 않음") { await other.view().locks.isEmpty }
    }

    // MARK: 충돌·보기만

    func testConflictKeepsTheRoomVersionAndTellsTheUser() async throws {
        // 소켓이 안 되는 망: 이 앱은 방송을 못 받아 낡은 사본으로 고치게 된다. 다시 붙기는 시험 동안 멈춰 둔다.
        // 끊긴 뒤 HTTP로 서버를 한 번 보는 일(잠금 표 받기)이 끝나야 다시 붙기 기다림에 들어간다.
        // 그 전에 다른 참여자가 잠그면 이 앱이 그 잠금을 받아 둔 채 풀림을 못 들어 충돌 대신 「고치는 중」이 났다(PRF1117A01, 시험 순서·시점 경쟁).
        let probed = ShareTestFlag()
        let frozen = ShareSessionEnvironment(sleep: { wait, seconds in
            if wait == .reconnect { await probed.set() }
            try await Task.sleep(for: .seconds(wait == .reconnect ? 3_600 : seconds))
        })
        let shared = try await share(session: frozen)
        let model = shared.model, other = shared.other, tripID = shared.tripID
        let itemID = try await add(shared, "성 구경", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z")
        await eventually("일정이 다른 참여자에게") { await other.item(itemID) != nil }
        await shared.server.setSocketsRefused(true)
        await eventually("소켓 없이도 고칠 수 있음") {
            let sockets = await shared.server.socketCount(roomID: shared.roomID)
            let theirs = await other.view().status
            let settled = await probed.isSet
            return sockets == 0 && settled && self.store.canEdit(tripID) && theirs == .live
        }
        await store.refresh(tripID: tripID)

        let current = await plan(other, itemID)
        var edited = try XCTUnwrap(current)
        (edited.title, edited.start, edited.end) = ("성 구경(먼저 고침)", 660, 720)
        try await other.lock(items: [itemID])
        _ = try await other.write([.update(id: itemID, content: .plan(edited))])
        try await other.unlock(items: [itemID])
        XCTAssertEqual(item(model, itemID)?.title, "성 구경", "방송을 못 받아 아직 낡은 사본")

        store.notice = nil
        let saved = await TripSharePlanEditor.updateItem(
            model: model, tripID: tripID, itemID: itemID, kind: .sight, title: "성 구경(늦게 고침)", start: stamp("2031-10-01T05:00:00Z"), end: stamp("2031-10-01T06:00:00Z")
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(store.notice, TripSharePlanText.conflict(.current))
        XCTAssertEqual(item(model, itemID)?.title, "성 구경(먼저 고침)", "로컬은 방의 최신본으로 바뀐다")
        XCTAssertEqual(item(model, itemID)?.start, stamp("2031-10-01T02:00:00Z"))
        let kept = await plan(other, itemID)
        XCTAssertEqual(kept?.title, "성 구경(먼저 고침)")
        await eventually("충돌 뒤 잠금을 남기지 않는다") { await other.lockState(item: itemID) == .free }

        // 최신본을 본 뒤 다시 고치면 된다.
        store.notice = nil
        let retried = await TripSharePlanEditor.updateItem(
            model: model, tripID: tripID, itemID: itemID, kind: .sight, title: "성 구경(다시 고침)", start: stamp("2031-10-01T05:00:00Z"), end: stamp("2031-10-01T06:00:00Z")
        )
        XCTAssertTrue(retried)
        XCTAssertNil(store.notice)
        XCTAssertEqual(item(model, itemID)?.title, "성 구경(다시 고침)")
    }

    func testOfflineIsViewOnlyAndTripInfoKeepsItsDates() async throws {
        let shared = try await share()
        let model = shared.model, other = shared.other, tripID = shared.tripID
        let old = try XCTUnwrap(model.settings.travelTrips?.first { $0.id == tripID })

        // 주인이 여행 정보를 고친다: 이름은 방에 쓰고, 날짜는 통째로 옮기지 않는다.
        var next = old
        (next.title, next.startDay, next.endDay) = ("가을 여행(수정)", "2031-10-05", "2031-10-06")
        store.notice = nil
        let saved = await TripSharePlanEditor.saveTrip(model: model, trip: next)
        XCTAssertEqual(saved?.title, "가을 여행(수정)")
        XCTAssertEqual([saved?.startDay, saved?.endDay], ["2031-10-01", "2031-10-02"])
        XCTAssertEqual(store.notice, TripSharePlanText.datesBlocked(.current))
        XCTAssertEqual(model.settings.travelTrips?.first { $0.id == tripID }?.title, "가을 여행(수정)")
        await eventually("여행 정보가 다른 참여자에게") { await other.view().meta?.name == "가을 여행(수정)" }
        let meta = await other.view().meta
        XCTAssertEqual(meta?.startDay, "2031-10-01")
        // 깃발 색은 이 기기에만 있는 값이라 방에 쓰지 않는다.
        var colored = try XCTUnwrap(saved)
        colored.flagColorHex = "#AA3322"
        let revision = await shared.server.rev(roomID: shared.roomID)
        store.notice = nil
        let recolored = await TripSharePlanEditor.saveTrip(model: model, trip: colored)
        XCTAssertEqual(recolored?.flagColorHex, "#AA3322")
        let sameRevision = await shared.server.rev(roomID: shared.roomID)
        XCTAssertEqual(sameRevision, revision)
        XCTAssertNil(store.notice)

        // 인터넷이 없으면 보기만: 넣기·고치기가 거절되고 로컬은 그대로다.
        let itemID = try await add(shared, "성 구경", "2031-10-01T01:00:00Z", "2031-10-01T02:00:00Z")
        await shared.server.setOffline(true)
        await eventually("보기만") { !self.store.canEdit(tripID) }
        store.notice = nil
        let added = await TripSharePlanEditor.addItem(
            model: model, tripID: tripID, kind: .meal, title: "점심", start: stamp("2031-10-01T03:00:00Z"), end: stamp("2031-10-01T04:00:00Z"), offsetSeconds: 32_400
        )
        XCTAssertNil(added)
        XCTAssertEqual(store.notice, TripShareText.viewOnly(.current))
        let moved = await TripSharePlanEditor.moveItem(model: model, tripID: tripID, itemID: itemID, by: 600)
        XCTAssertFalse(moved)
        XCTAssertEqual(model.settings.travelTripItems?.count, 1)
        XCTAssertEqual(item(model, itemID)?.start, stamp("2031-10-01T01:00:00Z"))
        var ran = 0
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .addStop(dayKey: "2031-10-01")) { ran += 1 }
        XCTAssertEqual(ran, 0)
    }

    // MARK: 초대로 들어온 기기

    func testAJoinedDeviceGetsTheTripFromTheRoomAndCannotChangeTripInfo() async throws {
        // 주인(다른 참여자)이 먼저 일정을 올려 둔다. 그 뒤 이 앱이 초대로 들어온다.
        let shared = try await share(appIsOwner: false)
        let model = shared.model, owner = shared.other, tripID = shared.tripID
        let (castle, market) = (ShareIdentifiers.itemID(), ShareIdentifiers.itemID())
        _ = try await owner.write([
            .create(id: castle, content: .plan(SharePlanContent(day: "2031-10-01", start: 600, end: 660, startOffset: 540, endOffset: 540, title: "성", place: "성 정문", planKind: "sight")), group: nil),
            .create(id: market, content: .plan(SharePlanContent(day: "2031-10-01", start: 720, end: 780, startOffset: 540, endOffset: 540, title: "시장", planKind: "meal", parentItemID: castle)), group: nil),
        ])
        await eventually("방의 여행과 일정이 로컬에") {
            model.settings.travelTrips?.first { $0.id == tripID }?.title == "가을 여행" && (model.settings.travelTripItems ?? []).count == 2
        }
        XCTAssertEqual(item(model, castle)?.start, stamp("2031-10-01T01:00:00Z"))
        XCTAssertEqual(item(model, market)?.parentItemID, castle)
        XCTAssertEqual(model.snapshot.plans.count, 2)
        XCTAssertEqual(model.settings.travelPlanStops, [], "장소는 이름만 오고 핀은 만들지 않는다")
        XCTAssertEqual(TripSharePlanEditor.placeName(tripID: tripID, itemID: castle), "성 정문")
        XCTAssertNil(TripSharePlanEditor.placeName(tripID: tripID, itemID: market))

        // 참여자도 일정은 고친다(방 항목 id가 곧 로컬 번호).
        let renamed = await TripSharePlanEditor.updateItem(
            model: model, tripID: tripID, itemID: castle, kind: .sight, title: "성(오전)", start: stamp("2031-10-01T01:00:00Z"), end: stamp("2031-10-01T02:00:00Z")
        )
        XCTAssertTrue(renamed)
        await eventually("참여자의 고침이 주인에게") { await self.plan(owner, castle)?.title == "성(오전)" }
        let kept = await plan(owner, castle)
        XCTAssertEqual(kept?.place, "성 정문", "장소를 건드리지 않으면 방의 이름을 지킨다")

        // 여행 정보는 주인만.
        var ran = 0
        store.notice = nil
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .tripInfo) { ran += 1 }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(store.notice, TripSharePlanText.ownerOnly(.current))
        var next = try XCTUnwrap(model.settings.travelTrips?.first { $0.id == tripID })
        next.title = "내 마음대로"
        store.notice = nil
        let saved = await TripSharePlanEditor.saveTrip(model: model, trip: next)
        XCTAssertNil(saved)
        XCTAssertEqual(store.notice, TripSharePlanText.ownerOnly(.current))
        XCTAssertEqual(model.settings.travelTrips?.first { $0.id == tripID }?.title, "가을 여행")

        // 주인이 지우면 로컬 일정과 일상 계획이 사라진다.
        try await owner.lock(items: [market])
        _ = try await owner.write([.delete(id: market)])
        await eventually("지워진 일정이 로컬에서도") { self.item(model, market) == nil }
        XCTAssertEqual(model.snapshot.plans.count, 1)
    }
}

/// 비동기 시험에서 한 번 일어난 일을 표시한다.
private actor ShareTestFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}
