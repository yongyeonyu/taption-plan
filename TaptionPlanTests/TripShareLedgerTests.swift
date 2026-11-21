import Synchronization
import XCTest
@testable import TaptionPlan
import TaptionLedgerCore
import TaptionPlanCore
import TaptionPlanStore
import TaptionTripShare
import TaptionTripShareTesting

/// 여행 공유 묶음 C(TSH1114A26): 가계부 범위·투영·정산·공유 예산·공지. 가짜 서버 위에서 이 기기(주인, 창구)와 다른 기기(세션)로 본다.
@MainActor
final class TripShareLedgerTests: XCTestCase {
    /// 올리거나 걷은 알림을 적어 두는 가짜 알림 센터.
    private final class AlertLog: Sendable {
        private let values = Mutex<(posted: [String], removed: [String])>(([], []))
        var posted: [String] { values.withLock { $0.posted } }
        var removed: [String] { values.withLock { $0.removed } }
        func center(allowed: Bool = true) -> TripShareNoticeAlerts.Center {
            TripShareNoticeAlerts.Center(
                isAllowed: { allowed },
                add: { alert, _, _ in self.values.withLock { $0.posted.append(alert.identifier) } },
                remove: { identifiers in self.values.withLock { $0.removed += identifiers } }
            )
        }
    }

    private let tripID = "t1"
    private var originalStore: TripShareStore!
    private var folder: URL!
    private var suiteName: String!
    private var server: ShareFakeServer!
    private var store: TripShareStore!
    private var book: LedgerBook!
    private var keys: ShareKeys!
    private var roomID: String!
    private var model: AppModel!
    private var alerts: AlertLog!
    private var others: [ShareRoomSession] = []

    override func setUp() async throws {
        originalStore = TripShareStore.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TripShareLedgerTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "TripShareLedgerTests-\(UUID().uuidString)"
        alerts = AlertLog()
        TripShareNoticeAlerts.center = alerts.center()
        TripShareNoticeAlerts.defaults = UserDefaults(suiteName: suiteName)!
        book = LedgerBook(store: { nil })
        TripShareLedger.book = book
        server = ShareFakeServer()
        store = TripShareStore(environment: TripShareEnvironment(
            transport: server.transport, secrets: TripShareMemorySecrets(), sidecar: TripShareSidecar(directory: folder), appKey: { "test-app-key" }
        ))
        TripShareStore.shared = store
        model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        store.attach(model)
    }

    override func tearDown() async throws {
        for session in others { await session.stop() }
        others = []
        await store.close(tripID: tripID)
        TripShareStore.shared = originalStore
        TripShareLedger.book = .shared
        TripShareNoticeAlerts.center = .system
        TripShareNoticeAlerts.defaults = .standard
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private func waitUntil(_ what: String = "", file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("기다린 일이 일어나지 않았다 \(what)", file: file, line: line)
    }

    /// 이 기기가 주인으로 방을 만들고 연다. 닉네임 「가을」, 앱 없는 일행 「겨울」.
    @discardableResult
    private func openRoom(shareAll: Bool? = nil, budget: Int? = nil) async throws -> ShareRoomSession {
        let invite = ShareInvite.make()
        roomID = invite.roomID
        keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: "가을여행-2031", iterations: 20)
        let ownerKey = ShareIdentifiers.ownerKey()
        let entry = try await ShareRoomClient.createRoom(
            transport: server.transport, appKey: "test-app-key",
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 86_400_000)
        )
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: tripID, role: .owner, phase: .sharing),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, ownerKey: ownerKey, member: entry.member, epoch: entry.epoch)
        )
        let opened = await store.open(tripID: tripID)
        let session = try XCTUnwrap(opened)
        await waitUntil("이 기기 연결") { await session.view().status == .live }
        _ = try await session.publish(card: ShareMemberCard(name: "가을", color: "#112233"))
        let trip = TravelTrip(id: tripID, title: "가을 여행", startDay: "2031-10-01", endDay: "2031-10-03")
        _ = try await session.publish(meta: TripShareMapping.meta(trip, budget: budget, guests: [ShareGuest(id: 1, name: "겨울")], shareAllExpenses: shareAll))
        await store.refresh(tripID: tripID)
        return session
    }

    /// 다른 기기가 초대로 들어온다.
    private func join(_ name: String) async throws -> ShareRoomSession {
        let entry = try await ShareRoomClient.join(transport: server.transport, roomID: roomID, proof: keys.proof)
        let session = ShareRoomSession(
            roomID: roomID, member: entry.member, epoch: entry.epoch, keys: keys,
            client: ShareRoomClient(transport: server.transport, roomID: roomID, token: entry.token, socketTimeout: 2)
        )
        others.append(session)
        await session.start()
        await waitUntil("다른 기기 연결") { await session.view().status == .live }
        _ = try await session.publish(card: ShareMemberCard(name: name, color: "#445566"))
        await waitUntil("이 기기가 새 사람을 봄") { self.store.names(tripID: self.tripID)?.others.contains(name) == true }
        return session
    }

    private func expense(_ title: String, _ amount: Double, source: LedgerEntry.Source = .manual) -> LedgerEntry {
        LedgerEntry(occurredAt: Date(timeIntervalSince1970: 1_950_000_000), amount: amount, amountKRW: amount, category: .food, title: title, tripID: tripID, source: source)
    }

    private func shared(in view: ShareRoomView) -> [(id: String, content: ShareExpenseContent)] {
        view.items(of: .expenseShared).compactMap { item in
            if case .sharedExpense(let content) = item.content { return (item.id, content) }
            return nil
        }
    }

    // MARK: 범위

    func testSharedExpenseGoesUpWithPayerAndSplitAndComesBackFromOthers() async throws {
        try await openRoom()
        let friend = try await join("봄")

        let dinner = expense("저녁", 30_000)
        let failure = await TripShareLedger.save(dinner, scope: .shared)
        XCTAssertNil(failure)
        XCTAssertEqual(TripShareLedger.scope(of: dinner), .shared)
        let local = try XCTUnwrap(book.entries.first { $0.id == dinner.id })
        XCTAssertEqual(Set(local.shareNames ?? []), [LedgerTrip.me, "봄", "겨울"], "「다 같이」는 그때의 사람들을 이름으로 적는다")
        XCTAssertNil(local.payer)

        // 다른 기기가 본 방의 내용: 누가 냈고 누구와 나눴는지.
        try await friend.catchUp()
        let seen = shared(in: await friend.view())
        XCTAssertEqual(seen.map(\.id), [TripShareMapping.roomItemID(entryID: dinner.id)])
        XCTAssertEqual(seen.first?.content.payer, .member(1))
        XCTAssertEqual(seen.first?.content.split, [.member(1), .member(2), .guest(1)])
        XCTAssertEqual([seen.first?.content.amount, seen.first?.content.amountKRW], [30_000, 30_000])

        // 다른 기기가 올린 공동 지출은 이 기기의 가계부에 들어온다.
        let taxiID = UUID()
        let taxi = ShareExpenseContent(title: "택시", amount: 12_000, currency: "KRW", amountKRW: 12_000, payer: .member(2), split: [.member(1), .member(2)], category: "transport", at: 1_950_000_100_000, by: 2)
        _ = try await friend.write([.create(id: TripShareMapping.roomItemID(entryID: taxiID), content: .sharedExpense(taxi), group: nil)])
        await waitUntil("투영") { self.book.entries.contains { $0.id == taxiID } }
        await waitUntil("여행 정보") { self.book.trip(tripID)?.members.isEmpty == false }
        var projected = try XCTUnwrap(book.entries.first { $0.id == taxiID })
        XCTAssertEqual([projected.title, projected.payer ?? "", projected.tripID ?? ""], ["택시", "봄", tripID])
        XCTAssertEqual(Set(projected.shareNames ?? []), [LedgerTrip.me, "봄"])
        XCTAssertEqual(projected.category, .transport)
        XCTAssertEqual(book.trip(tripID)?.members, ["봄", "겨울"], "여행 장부가 없으면 여행 정보로 만들고 동행은 방 사람들")
        XCTAssertNil(book.trip(tripID)?.budgetKRW)

        // 고치면 따라오고(잠금 뒤 쓰기), 지우면 가계부에서도 사라진다.
        var cheaper = taxi
        cheaper.amount = 9_000
        cheaper.amountKRW = 9_000
        let roomTaxiID = TripShareMapping.roomItemID(entryID: taxiID)
        try await friend.lock(items: [roomTaxiID])
        _ = try await friend.write([.update(id: roomTaxiID, content: .sharedExpense(cheaper))])
        try await friend.unlock(items: [roomTaxiID])
        await waitUntil("고친 금액") { self.book.entries.first { $0.id == taxiID }?.amount == 9_000 }
        projected = try XCTUnwrap(book.entries.first { $0.id == taxiID })
        XCTAssertEqual(projected.amountKRW, 9_000)

        // 이 기기가 남이 올린 것을 지워도 된다(공동 지출은 누구나).
        let removal = await TripShareLedger.remove(projected)
        XCTAssertNil(removal)
        XCTAssertFalse(book.entries.contains { $0.id == taxiID })
        await waitUntil("다른 기기에서도 사라짐") { await friend.view().items(of: .expenseShared).count == 1 }

        // 남이 지우면 이 기기의 가계부에서도 사라진다.
        let roomDinnerID = TripShareMapping.roomItemID(entryID: dinner.id)
        try await friend.lock(items: [roomDinnerID])
        _ = try await friend.write([.delete(id: roomDinnerID)])
        await waitUntil("지움 전파") { !self.book.entries.contains { $0.id == dinner.id } }
    }

    func testOwnScopesAndChangingScopeMakesANewItem() async throws {
        try await openRoom()
        let friend = try await join("봄")

        // 비공개: 방에 아무것도 없고, 몫은 나만.
        let snack = expense("간식", 4_000)
        let hiddenFailure = await TripShareLedger.save(snack, scope: .ownHidden)
        XCTAssertNil(hiddenFailure)
        XCTAssertEqual(book.entries.first { $0.id == snack.id }?.shareNames, TripShareMapping.privateShare)
        XCTAssertEqual(TripShareLedger.scope(of: snack), .ownHidden)

        // 공개한 개인 지출: 방에 `expense-own`으로, 정산에는 없다. 남은 못 고친다.
        let gift = expense("선물", 20_000)
        let openFailure = await TripShareLedger.save(gift, scope: .ownOpen)
        XCTAssertNil(openFailure)
        XCTAssertEqual(TripShareLedger.scope(of: gift), .ownOpen)
        try await friend.catchUp()
        var seen = await friend.view()
        XCTAssertEqual(seen.items(of: .expenseOwn).map(\.id), [TripShareMapping.roomItemID(entryID: gift.id)])
        XCTAssertTrue(seen.items(of: .expenseShared).isEmpty, "비공개 지출은 어디에도 올라가지 않는다")
        let giftRoomID = TripShareMapping.roomItemID(entryID: gift.id)
        do {
            _ = try await friend.write([.delete(id: giftRoomID)])
            XCTFail("남의 개인 지출은 지우지 못한다")
        } catch {
            XCTAssertEqual(error as? ShareError, .readOnly(.notAllowed))
        }

        // 남이 공개한 개인 지출은 내 가계부에 들어오지 않고 방 사본에서만 보인다.
        _ = try await friend.write([.create(.ownExpense(ShareOwnExpenseContent(amount: 7_000, currency: "KRW", memo: "기념품", at: 1_950_000_200_000, by: 2)))])
        await waitUntil("남의 공개 지출") { self.store.view(tripID: self.tripID)?.items(of: .expenseOwn).count == 2 }
        let view = try XCTUnwrap(store.view(tripID: tripID)), names = try XCTUnwrap(store.names(tripID: tripID))
        XCTAssertEqual(TripShareLedger.openExpenses(of: view, names: names).map { [$0.name, $0.title, "\(Int($0.amount))"] }, [["봄", "기념품", "7000"]])
        XCTAssertEqual(book.tripEntries(tripID).map(\.title).sorted(), ["간식", "선물"])

        // 개인 → 공동: 방에서는 지우고 새로 만든다. 로컬 번호도 새 것이고 기록은 하나다.
        let saved = try XCTUnwrap(book.entries.first { $0.id == gift.id })
        let moved = await TripShareLedger.save(saved, scope: .shared)
        XCTAssertNil(moved)
        XCTAssertFalse(book.entries.contains { $0.id == gift.id })
        let now = try XCTUnwrap(book.tripEntries(tripID).first { $0.title == "선물" })
        XCTAssertNotEqual(now.id, gift.id)
        XCTAssertEqual(TripShareLedger.scope(of: now), .shared)
        try await friend.catchUp()
        seen = await friend.view()
        XCTAssertEqual(seen.items(of: .expenseShared).map(\.id), [TripShareMapping.roomItemID(entryID: now.id)])
        XCTAssertFalse(seen.items.contains { $0.id == giftRoomID })

        // 공동 → 비공개: 방에서 내려오고 이 기기에만 남는다.
        let back = await TripShareLedger.save(now, scope: .ownHidden)
        XCTAssertNil(back)
        try await friend.catchUp()
        seen = await friend.view()
        XCTAssertTrue(seen.items(of: .expenseShared).isEmpty)
        let kept = book.tripEntries(tripID).filter { $0.title == "선물" }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.shareNames, TripShareMapping.privateShare)
        XCTAssertEqual(kept.first.map(TripShareLedger.scope(of:)), .ownHidden)
    }

    /// 지출 폼이 방에서 지금 범위를 읽기 전(처음 값 「나만」)에 저장해도 공동 지출이 방에서 지워지지 않는다(REV1117A01).
    func testSavingBeforeTheFormHasReadTheScopeKeepsASharedExpenseShared() async throws {
        try await openRoom()
        let friend = try await join("봄")
        let dinner = expense("저녁", 30_000)
        let first = await TripShareLedger.save(dinner, scope: .shared)
        XCTAssertNil(first)
        let saved = try XCTUnwrap(book.entries.first { $0.id == dinner.id })
        let roomID = TripShareMapping.roomItemID(entryID: saved.id)

        TripShareLedger.pendingScopeForms.insert(saved.id)
        defer { TripShareLedger.pendingScopeForms.remove(saved.id) }
        var edited = saved
        edited.title = "저녁(고침)"
        let second = await TripShareLedger.save(edited, scope: .ownHidden)
        XCTAssertNil(second, "폼의 처음 값 「나만」은 믿지 않는다")

        try await friend.catchUp()
        let seen = shared(in: await friend.view())
        XCTAssertEqual(seen.map(\.id), [roomID], "방의 공동 지출은 그대로 있고")
        XCTAssertEqual(seen.first?.content.title, "저녁(고침)", "고친 내용이 올라간다")
        XCTAssertEqual(book.entries.filter { $0.title.hasPrefix("저녁") }.map(\.id), [saved.id], "로컬 기록도 새 번호를 받지 않는다")
    }

    /// 대표 결정: 자동으로 들어온 지출(문자·알림·AI)은 방에 올리지 않는다. 사용자가 직접 「공동」으로 고른 것만 올라간다.
    func testAutomaticEntriesNeverReachTheRoom() async throws {
        try await openRoom(shareAll: true)
        let friend = try await join("봄")

        // 자동 기록은 가계부에 바로 들어온다(`LedgerBook.save`). 「내 지출 전부 공유」가 켜져 있어도 올라가지 않는다.
        for source in [LedgerEntry.Source.message, .assistant, .receipt] {
            await book.save(expense("자동 \(source.rawValue)", 5_000, source: source))
        }
        XCTAssertEqual(TripShareLedger.defaultScope(for: expense("자동", 5_000, source: .message)), .ownHidden, "자동 기록의 처음 범위는 늘 비공개")
        XCTAssertEqual(TripShareLedger.defaultScope(for: expense("직접", 5_000)), .shared, "직접 넣는 지출만 여행 기본값을 따른다")

        // 방이 바뀌어 투영이 여러 번 돌아도 그대로다.
        let manual = expense("직접 넣은 점심", 18_000)
        let failure = await TripShareLedger.save(manual, scope: .shared)
        XCTAssertNil(failure)
        _ = try await friend.write([.create(.notice(ShareNoticeContent(text: "모이자", createdAt: 1_950_000_000_000, by: 2)))])
        let view = try XCTUnwrap(store.view(tripID: tripID))
        await TripShareLedger.project(tripID: tripID, roomID: roomID, view: view)

        try await friend.catchUp()
        let seen = await friend.view()
        XCTAssertEqual(shared(in: seen).map(\.content.title), ["직접 넣은 점심"], "방에는 직접 고른 지출 하나뿐")
        XCTAssertTrue(seen.items(of: .expenseOwn).isEmpty)
        let automatic = book.tripEntries(tripID).filter { $0.source != .manual }
        XCTAssertEqual(automatic.count, 3, "자동 기록은 이 기기에 그대로 남는다")
        XCTAssertTrue(automatic.allSatisfy { $0.shareNames == TripShareMapping.privateShare }, "방에 없는 지출의 몫은 나만")
        XCTAssertTrue(automatic.allSatisfy { TripShareLedger.scope(of: $0) == .ownHidden })
    }

    /// 나간 사람은 카드가 지워져도 이름이 남고, 그 사람이 낀 공동 지출을 고칠 수 있다(TSA1117A01).
    func testAMemberWhoLeftKeepsTheirNameAndTheirExpensesStayEditable() async throws {
        try await openRoom()
        let friend = try await join("봄")
        let dinner = expense("저녁", 30_000)
        let saved = await TripShareLedger.save(dinner, scope: .shared)
        XCTAssertNil(saved)

        try await friend.leave()
        await waitUntil("나간 사람의 카드가 사라짐") { self.store.view(tripID: self.tripID)?.cards[2] == nil }
        let view = try XCTUnwrap(store.view(tripID: tripID))
        await TripShareLedger.project(tripID: tripID, roomID: roomID, view: view)
        let local = try XCTUnwrap(book.entries.first { $0.id == dinner.id })
        XCTAssertEqual(Set(local.shareNames ?? []), [LedgerTrip.me, "봄", "겨울"], "나간 사람도 `m2`가 아니라 이름으로 보인다")
        XCTAssertEqual(store.names(tripID: tripID)?.name(.member(2)), "봄")
        XCTAssertFalse(store.names(tripID: tripID)?.others.contains("봄") ?? true, "새 지출에서 고를 사람에는 없다")

        var edited = local
        edited.amount = 36_000
        edited.amountKRW = 36_000
        let failure = await TripShareLedger.save(edited, scope: .shared)
        XCTAssertNil(failure, "나간 사람이 낀 지출도 고칠 수 있다")
        let content = try XCTUnwrap(shared(in: try XCTUnwrap(store.view(tripID: tripID))).first?.content)
        XCTAssertEqual(content.split, [.member(1), .member(2), .guest(1)], "몫은 그대로")
        XCTAssertEqual(content.amount, 36_000)

        // 앱을 다시 켜도(창구를 새로 만들어도) 지난 이름을 곁 파일에서 읽는다.
        await store.close(tripID: tripID)
        let reopened = TripShareStore(environment: store.environment)
        TripShareStore.shared = reopened
        store = reopened
        let again = await reopened.open(tripID: tripID)
        XCTAssertNotNil(again)
        XCTAssertEqual(reopened.names(tripID: tripID)?.name(.member(2)), "봄")
    }

    /// 대표 결정(2026-11-17): 공유를 시작할 때 있던 「다 같이」 지출은 나만으로 바꾸지 않고, 방에 들어온 동행 모두로 나눈다(TSA1117A01).
    /// 자동으로 들어온 지출은 대표 결정대로 올리지 않는다.
    func testAllTogetherExpensesFromBeforeSharingAreSplitWithEveryoneWhoJoins() async throws {
        let trip = TravelTrip(id: tripID, title: "가을 여행", startDay: "2031-10-01", endDay: "2031-10-03")
        _ = await model.saveTravelTrip(trip)
        let before = expense("숙소", 90_000)
        let mine = { var entry = self.expense("기념품", 10_000); entry.shareNames = [LedgerTrip.me]; return entry }()
        let automatic = expense("문자 결제", 5_000, source: .message)
        // 대표 결정(2026-11-18): 자동 기록이라도 사용자가 폼에서 「다 같이」를 고른 것은 올린다.
        var taxi = expense("택시", 30_000, source: .message)
        taxi.shareChosen = true
        for entry in [before, mine, automatic, taxi] { await book.save(entry) }

        let invite = ShareInvite.make()
        roomID = invite.roomID
        keys = try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: "가을여행-2031", iterations: 20)
        let ownerKey = ShareIdentifiers.ownerKey()
        let entry = try await ShareRoomClient.createRoom(
            transport: server.transport, appKey: "test-app-key",
            request: ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 86_400_000)
        )
        try store.register(
            TripShareLink(roomID: invite.roomID, tripID: tripID, role: .owner, phase: .uploading),
            secrets: ShareRoomSecrets(root: keys.root, linkSecret: invite.linkSecret, token: entry.token, ownerKey: ownerKey, member: entry.member, epoch: entry.epoch)
        )
        try await TripShareCreation.upload(model: model, store: store, tripID: tripID)
        XCTAssertEqual(store.link(tripID: tripID)?.phase, .sharing)
        let uploaded = shared(in: try XCTUnwrap(store.view(tripID: tripID)))
        XCTAssertEqual(Set(uploaded.map(\.id)), Set([before.id, taxi.id].map(TripShareMapping.roomItemID(entryID:))),
                       "직접 넣었거나 사용자가 「다 같이」로 고른 지출만 공동 지출로 올라간다")
        XCTAssertEqual(book.entries.first { $0.id == mine.id }?.shareNames, [LedgerTrip.me])

        // 동행이 들어오면 그 사람도 몫에 들어가고 정산에 바로 잡힌다.
        let friend = try await join("봄")
        await waitUntil("들어온 사람이 몫에 들어감") {
            self.shared(in: self.store.view(tripID: self.tripID)!).allSatisfy { $0.content.split == [.member(1), .member(2)] }
        }
        try await friend.catchUp()
        let friendView = await friend.view()
        XCTAssertEqual(shared(in: friendView).map(\.content.split), [[.member(1), .member(2)], [.member(1), .member(2)]])
        await waitUntil("가계부에도 둘로") { Set(self.book.entries.first { $0.id == before.id }?.shareNames ?? []) == [LedgerTrip.me, "봄"] }
        // 자동 기록은 올리지 않고, 공유 중의 다음 맞춤에서 나만으로 고정된다(예전과 같다).
        XCTAssertEqual(book.entries.first { $0.id == automatic.id }?.shareNames, TripShareMapping.privateShare, "자동 기록은 올리지 않는다")

        // 공유 뒤에 새로 넣은 「다 같이」는 그때의 사람들 그대로다(나중 사람에게 몫이 생기지 않는다).
        let later = expense("저녁", 20_000)
        let failure = await TripShareLedger.save(later, scope: .shared)
        XCTAssertNil(failure)
        let third = try await join("여름")
        _ = third
        try await Task.sleep(for: .milliseconds(300))
        let byID = Dictionary(uniqueKeysWithValues: shared(in: try XCTUnwrap(store.view(tripID: tripID))).map { ($0.id, $0.content.split) })
        XCTAssertEqual(byID[TripShareMapping.roomItemID(entryID: later.id)], [.member(1), .member(2)])
        await waitUntil("공유 전 지출은 셋째도") { self.shared(in: self.store.view(tripID: self.tripID)!).first { $0.id == TripShareMapping.roomItemID(entryID: before.id) }?.content.split == [.member(1), .member(2), .member(3)] }
    }

    func testOfflineSharedSaveIsRefusedAndNothingIsWritten() async throws {
        try await openRoom()
        await server.setOffline(true)
        let lunch = expense("점심", 9_000)
        let failure = await TripShareLedger.save(lunch, scope: .shared)
        XCTAssertEqual(failure, .viewOnly)
        XCTAssertTrue(book.entries.isEmpty, "서버가 받아 주지 않은 공동 지출은 가계부에도 쓰지 않는다")
        // 비공개는 인터넷 없이도 된다.
        let hidden = await TripShareLedger.save(lunch, scope: .ownHidden)
        XCTAssertNil(hidden)
        XCTAssertEqual(book.entries.map(\.id), [lunch.id])
    }

    // MARK: 꺼진 동안 방에서 지워진 공동 지출(TSF1115A01)

    /// 앱을 껐다 켠 것처럼 만든다. 곁 파일의 방 사본은 `stale`(그 지출이 담기기 전에 꺼진 경우)로 되돌린다.
    private func relaunch(with stale: ShareRoomSnapshot) async throws {
        // 늦게 도는 사본 저장(1초 뒤)이 되돌린 사본을 덮지 않게 먼저 끝나기를 기다린다.
        try await Task.sleep(for: .milliseconds(1_300))
        await store.close(tripID: tripID)
        try store.environment.sidecar.save(stale)
        TripShareLedger.forgetMemory()
        store = TripShareStore(environment: store.environment)
        TripShareStore.shared = store
        store.attach(model)
    }

    private func friendAdds(_ friend: ShareRoomSession, _ title: String) async throws -> (entryID: UUID, roomItemID: String) {
        let entryID = UUID(), roomItemID = TripShareMapping.roomItemID(entryID: entryID)
        let content = ShareExpenseContent(title: title, amount: 12_000, currency: "KRW", amountKRW: 12_000, payer: .member(2), split: [.member(1), .member(2)], category: "transport", at: 1_950_000_100_000, by: 2)
        _ = try await friend.write([.create(id: roomItemID, content: .sharedExpense(content), group: nil)])
        await waitUntil("투영 \(title)") { self.book.entries.contains { $0.id == entryID } }
        return (entryID, roomItemID)
    }

    func testExpenseDeletedWhileTheAppWasOffIsSweptOnlyAfterTheRoomIsFullyReceived() async throws {
        let session = try await openRoom()
        let friend = try await join("봄")
        // 방에 올리지 않은 내 지출.
        let snack = expense("간식", 3_000)
        let hidden = await TripShareLedger.save(snack, scope: .ownHidden)
        XCTAssertNil(hidden)
        let dinner = try await friendAdds(friend, "저녁")
        let early = await session.snapshot()
        let taxi = try await friendAdds(friend, "택시")
        let sidecar = store.environment.sidecar
        XCTAssertEqual(sidecar.projectedExpenses(roomID: roomID), [dinner.roomItemID, taxi.roomItemID], "가계부에 넣은 방 지출은 곁 파일에 적어 둔다")

        // 택시가 방 사본에 담기기 전에 앱이 꺼졌고, 꺼진 동안 방에서 택시가 지워진다.
        try await relaunch(with: early)
        try await friend.lock(items: [taxi.roomItemID])
        _ = try await friend.write([.delete(id: taxi.roomItemID)])

        // 인터넷 없이 켜면 덜 받은 상태다: 지우지 않는다.
        await server.setOffline(true)
        let opened = await store.open(tripID: tripID)
        let reopened = try XCTUnwrap(opened)
        await waitUntil("인터넷 없음") { await reopened.view().status == .offline }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(book.entries.contains { $0.id == taxi.entryID }, "덜 받은 동안에는 지우지 않는다")

        // 연결돼 끝까지 받으면 방에 없는 「방에서 온」 지출만 정리된다.
        await server.setOffline(false)
        await waitUntil("다 받은 뒤 정리") { !self.book.entries.contains { $0.id == taxi.entryID } }
        XCTAssertTrue(book.entries.contains { $0.id == dinner.entryID }, "방에 남아 있는 공동 지출은 그대로")
        XCTAssertTrue(book.entries.contains { $0.id == snack.id }, "방에 올리지 않은 내 지출은 건드리지 않는다")
        XCTAssertEqual(sidecar.projectedExpenses(roomID: roomID), [dinner.roomItemID])
    }

    func testSweepLeavesEverythingUntilTheRoomIsFullyReadable() async throws {
        try await openRoom()
        let friend = try await join("봄")
        let snack = expense("간식", 3_000)
        _ = await TripShareLedger.save(snack, scope: .ownHidden)
        let taxi = try await friendAdds(friend, "택시")
        let link = try XCTUnwrap(store.link(tripID: tripID))
        // 방 사본에 택시가 아직 없는 화면 값(덜 받았거나, 정말 지워졌거나).
        var view = try XCTUnwrap(store.view(tripID: tripID))
        view.items.removeAll { $0.id == taxi.roomItemID }
        let kept = { self.book.entries.contains { $0.id == taxi.entryID } }

        for status in [ShareSessionStatus.connecting, .offline, .needsRekey, .replaced] {
            view.status = status
            await TripShareLedger.sweep(tripID: tripID, roomID: roomID, view: view)
            XCTAssertTrue(kept(), "\(status)에서는 지우지 않는다")
        }
        view.status = .live
        view.unreadable = [try JSONDecoder().decode(ShareUnreadableItem.self, from: Data(#"{"id":"\#(taxi.roomItemID)","kind":"expenseShared","rev":3}"#.utf8))]
        await TripShareLedger.sweep(tripID: tripID, roomID: roomID, view: view)
        XCTAssertTrue(kept(), "풀지 못한 항목이 있으면 지우지 않는다")
        view.unreadable = []

        // 연결만 된 때(`.live` 직후)와 올리는 중에는 정리하지 않는다. 다 받았다는 알림에서만 한다.
        TripShareLedger.forgetMemory()
        await TripShareLedger.roomChanged(model: model, link: link, view: view, event: .status(.live))
        XCTAssertTrue(kept(), "연결 직후에는 지우지 않는다")
        var uploading = link
        uploading.phase = .uploading
        await TripShareLedger.roomChanged(model: model, link: uploading, view: view, event: .caughtUp)
        XCTAssertTrue(kept(), "올리는 중에는 지우지 않는다")

        await TripShareLedger.roomChanged(model: model, link: link, view: view, event: .caughtUp)
        XCTAssertFalse(kept(), "다 받은 뒤에는 방에 없는 방 지출을 지운다")
        XCTAssertTrue(book.entries.contains { $0.id == snack.id }, "방에 올리지 않은 내 지출은 건드리지 않는다")
        XCTAssertEqual(store.environment.sidecar.projectedExpenses(roomID: roomID), [])
    }

    // MARK: 정산·예산

    func testSettlementIsTheSameOnEveryDeviceAndClosingBlocksSharedExpenses() async throws {
        let session = try await openRoom()
        let friend = try await join("봄")

        // 내가 3만 원을 셋(나·봄·겨울)이 나눠 쓰고, 봄이 엔화 지출을 원화 환산과 함께 올린다. 나눌 사람이 빈 것은 낸 사람 혼자다.
        let first = await TripShareLedger.save(expense("저녁", 30_000), scope: .shared)
        XCTAssertNil(first)
        _ = try await friend.write([
            .create(.sharedExpense(ShareExpenseContent(title: "입장료", amount: 2_000, currency: "JPY", amountKRW: 18_001, payer: .member(2), split: [.member(1), .member(2)], at: 1_950_000_300_000, by: 2))),
            .create(.sharedExpense(ShareExpenseContent(title: "혼자 쓴 것", amount: 50_000, currency: "KRW", amountKRW: 50_000, payer: .member(2), split: [], at: 1_950_000_400_000, by: 2))),
        ])
        await waitUntil("공동 지출 셋") { self.store.view(tripID: self.tripID)?.items(of: .expenseShared).count == 3 }

        let view = try XCTUnwrap(store.view(tripID: tripID)), names = try XCTUnwrap(store.names(tripID: tripID))
        let mine = TripShareSettlementSummary(view: view, names: names)
        try await friend.catchUp()
        let theirView = await friend.view()
        let theirs = TripShareSettlementSummary(view: theirView, names: TripShareNames(me: 2, cards: theirView.cards, guests: theirView.meta?.guests ?? []))
        XCTAssertEqual(mine.settlements, theirs.settlements, "같은 방이면 어느 기기에서나 같은 정산")
        XCTAssertEqual(mine.settlements.map(\.currency), ["KRW"], "원화 환산이 있으면 원화로 센다")
        XCTAssertEqual(mine.spentKRW, 98_001)
        // 나: 낸 돈 30,000, 몫 10,000 + 9,001(나머지 1원은 번호가 앞선 내가) → +10,999. 봄: 낸 돈 68,001, 몫 10,000 + 9,000 + 50,000 → −999. 겨울: −10,000.
        XCTAssertEqual(mine.settlements.first?.balances.map(\.net), [10_999, -999, -10_000])
        XCTAssertEqual(mine.transfers.map(\.key), ["g1>m1:KRW:10000", "m2>m1:KRW:999"])

        // 주인이 마감하면 공동 지출은 넣지도 고치지도 지우지도 못한다. 개인 지출은 된다.
        let closing = await TripShareSettlement.setClosed(true, tripID: tripID)
        XCTAssertNil(closing)
        XCTAssertEqual(store.view(tripID: tripID)?.closed, true)
        let late = await TripShareLedger.save(expense("늦은 지출", 1_000), scope: .shared)
        XCTAssertEqual(late, .closed)
        let dinner = try XCTUnwrap(book.tripEntries(tripID).first { $0.title == "저녁" })
        let removal = await TripShareLedger.remove(dinner)
        XCTAssertEqual(removal, .closed)
        XCTAssertTrue(book.entries.contains { $0.id == dinner.id })
        XCTAssertEqual(TripShareLedger.defaultScope(for: expense("직접", 1_000)), .ownHidden)
        let own = await TripShareLedger.save(expense("내 것", 1_000), scope: .ownOpen)
        XCTAssertNil(own)

        // 「보냄」은 보낸 사람의 카드에 있어 마감 뒤에도 된다. 내가 보낼 것이 아니면 표시하지 못한다.
        let transfer = try XCTUnwrap(mine.transfers.last)
        let notMine = await TripShareSettlement.setSent(transfer, sent: true, tripID: tripID)
        XCTAssertEqual(notMine, .viewOnly)
        var card = try XCTUnwrap(theirView.cards[2])
        card.sent = [transfer.key, "m2>m1:KRW:1"]
        _ = try await friend.publish(card: card)
        await waitUntil("보냄 표시") { self.store.view(tripID: self.tripID)?.cards[2]?.sent?.contains(transfer.key) == true }
        let after = TripShareSettlementSummary(view: try XCTUnwrap(store.view(tripID: tripID)), names: names)
        XCTAssertTrue(after.sent.contains(transfer.key))
        XCTAssertTrue(after.closed)

        // 주인이 다시 열면 넣을 수 있다. 참여자는 마감하지 못한다.
        let reopening = await TripShareSettlement.setClosed(false, tripID: tripID)
        XCTAssertNil(reopening)
        let again = await TripShareLedger.save(expense("늦은 지출", 1_000), scope: .shared)
        XCTAssertNil(again)
        do {
            try await friend.setSettlementClosed(true)
            XCTFail("참여자는 마감하지 못한다")
        } catch {}
        _ = session
    }

    func testSharedBudgetLivesInTheRoomAndLeavesTheTripLedgerBudgetAlone() async throws {
        await book.saveTrip(LedgerTrip(id: tripID, name: "가을 여행", start: Date(timeIntervalSince1970: 1_949_900_000), end: Date(timeIntervalSince1970: 1_950_100_000), budgetKRW: 300_000))
        let funding = book.entries.filter { $0.transfer != nil }
        XCTAssertEqual(funding.count, 2, "내 여행 예산은 일상↔여행 짝 기록으로 있다")
        try await openRoom(budget: 500_000)

        let failure = await TripShareLedger.setSharedBudget(800_000, tripID: tripID)
        XCTAssertNil(failure)
        XCTAssertEqual(store.view(tripID: tripID)?.meta?.budget, 800_000)
        let saved = await TripShareLedger.save(expense("저녁", 30_000), scope: .shared)
        XCTAssertNil(saved)
        await waitUntil("투영이 장부를 맞춤") { self.book.trip(self.tripID)?.members == ["겨울"] }

        XCTAssertEqual(book.trip(tripID)?.budgetKRW, 300_000, "공유 예산은 내 여행 장부의 예산을 바꾸지 않는다")
        XCTAssertEqual(book.entries.filter { $0.transfer != nil }, funding, "예산 이체 짝 기록도 그대로")
        let view = try XCTUnwrap(store.view(tripID: tripID)), names = try XCTUnwrap(store.names(tripID: tripID))
        let summary = TripShareSettlementSummary(view: view, names: names)
        XCTAssertEqual([summary.budget ?? 0, summary.spentKRW], [800_000, 30_000])

        let cleared = await TripShareLedger.setSharedBudget(nil, tripID: tripID)
        XCTAssertNil(cleared)
        XCTAssertNil(store.view(tripID: tripID)?.meta?.budget)
        XCTAssertEqual(book.trip(tripID)?.budgetKRW, 300_000)
    }

    func testNicknameChangeRewritesProjectedNames() async throws {
        try await openRoom()
        let friend = try await join("봄")
        let taxiID = UUID()
        let taxi = ShareExpenseContent(title: "택시", amount: 12_000, currency: "KRW", amountKRW: 12_000, payer: .member(2), split: [.member(1), .member(2)], at: 1_950_000_100_000, by: 2)
        _ = try await friend.write([.create(id: TripShareMapping.roomItemID(entryID: taxiID), content: .sharedExpense(taxi), group: nil)])
        await waitUntil("투영") { self.book.entries.first { $0.id == taxiID }?.payer == "봄" }

        _ = try await friend.publish(card: ShareMemberCard(name: "여름", color: "#445566"))
        await waitUntil("이름 다시 쓰기") { self.book.entries.first { $0.id == taxiID }?.payer == "여름" }
        XCTAssertEqual(Set(book.entries.first { $0.id == taxiID }?.shareNames ?? []), [LedgerTrip.me, "여름"])
        await waitUntil("동행") { self.book.trip(self.tripID)?.members == ["여름", "겨울"] }
    }

    // MARK: 공지

    func testNoticesPostAcknowledgeAndAlertOnlyOnce() async throws {
        try await openRoom()
        let friend = try await join("봄")

        // 남이 올린 공지: 띠에 뜨고, 허용돼 있으면 알림을 한 번 올린다. 시각이 있으면 그 전에 한 번 더.
        let noticeID = ShareIdentifiers.itemID()
        let due = Int((Date.now.addingTimeInterval(7_200).timeIntervalSince1970 * 1000).rounded())
        let notice = ShareNoticeContent(text: "세 시에 정문 앞", important: true, createdAt: 1_950_000_000_000, due: due, place: "정문", by: 2)
        _ = try await friend.write([.create(id: noticeID, content: .notice(notice), group: nil)])
        await waitUntil("공지 알림") { self.alerts.posted.count == 2 }
        XCTAssertEqual(alerts.posted, [TripShareNoticeAlerts.identifier(noticeID), TripShareNoticeAlerts.dueIdentifier(noticeID)])
        var view = try XCTUnwrap(store.view(tripID: tripID))
        XCTAssertEqual(TripShareNoticeAlerts.pending(in: view).map(\.item.id), [noticeID])
        var names = try XCTUnwrap(store.names(tripID: tripID))
        var row = try XCTUnwrap(TripShareNotices.rows(view: view, names: names).first)
        XCTAssertEqual([row.author, row.place ?? "", row.text], ["봄", "정문", "세 시에 정문 앞"])
        XCTAssertTrue(row.needsMyAck)
        XCTAssertEqual([row.done, row.waiting], [[], ["가을"]])

        // 다른 변화가 와도 같은 공지를 다시 알리지 않는다.
        let saved = await TripShareLedger.save(expense("저녁", 30_000), scope: .shared)
        XCTAssertNil(saved)
        let link = try XCTUnwrap(store.link(tripID: tripID)), latest = try XCTUnwrap(store.view(tripID: tripID))
        await TripShareNoticeAlerts.roomChanged(model: model, link: link, view: latest, event: .items(changed: [], removed: []))
        XCTAssertEqual(alerts.posted.count, 2)

        // 확인하면 다른 기기가 알고, 올린 알림은 걷는다.
        let acked = await TripShareNotices.acknowledge(noticeID: noticeID, tripID: tripID)
        XCTAssertNil(acked)
        view = try XCTUnwrap(store.view(tripID: tripID))
        XCTAssertTrue(TripShareNoticeAlerts.pending(in: view).isEmpty)
        await waitUntil("알림 걷기") { self.alerts.removed.contains(TripShareNoticeAlerts.identifier(noticeID)) }
        XCTAssertTrue(alerts.removed.contains(TripShareNoticeAlerts.dueIdentifier(noticeID)))
        await waitUntil("보낸 사람이 확인을 봄") { await friend.view().items(of: .notice).first?.acks[1] != nil }

        // 쓴 사람이 고치면 확인이 비워지고 다시 알린다.
        var edited = notice
        edited.text = "네 시로 바뀜"
        edited.due = nil
        _ = try await friend.write([.update(id: noticeID, content: .notice(edited))])
        await waitUntil("다시 알림") { self.alerts.posted.count == 3 }
        XCTAssertEqual(TripShareNoticeAlerts.pending(in: try XCTUnwrap(store.view(tripID: tripID))).map(\.notice.text), ["네 시로 바뀜"])

        // 내가 올린 공지: 좌표 없이 글·장소 이름만. 나는 확인할 필요가 없고, 누가 아직인지 이름으로 본다.
        let posted = await TripShareNotices.post(text: "  내일 아침 8시 출발  ", important: false, place: "숙소 앞", tripID: tripID)
        XCTAssertNil(posted)
        let empty = await TripShareNotices.post(text: "   ", tripID: tripID)
        XCTAssertEqual(empty, .failed)
        view = try XCTUnwrap(store.view(tripID: tripID))
        names = try XCTUnwrap(store.names(tripID: tripID))
        row = try XCTUnwrap(TripShareNotices.rows(view: view, names: names).first { $0.isMine })
        XCTAssertEqual([row.text, row.place ?? ""], ["내일 아침 8시 출발", "숙소 앞"])
        XCTAssertFalse(row.needsMyAck)
        XCTAssertEqual(row.waiting, ["봄"])
        let mineID = row.id
        let json = try XCTUnwrap(view.items.first { $0.id == mineID }?.json)
        for word in ["lat", "lon", "coordinate"] { XCTAssertFalse(json.lowercased().contains(word), "공지에 좌표가 없다") }
        try await friend.catchUp()
        try await friend.acknowledge(noticeID: mineID)
        await waitUntil("확인 현황") {
            guard let view = self.store.view(tripID: self.tripID), let names = self.store.names(tripID: self.tripID) else { return false }
            return TripShareNotices.rows(view: view, names: names).first { $0.id == mineID }?.done == ["봄"]
        }
        XCTAssertEqual(alerts.posted.count, 3, "내가 쓴 공지는 나에게 알리지 않는다")

        // 내 공지는 내가 지운다.
        let deleted = await TripShareNotices.delete(noticeID: mineID, tripID: tripID)
        XCTAssertNil(deleted)
        XCTAssertFalse(try XCTUnwrap(store.view(tripID: tripID)).items.contains { $0.id == mineID })
    }

    func testNoticeAlertsStaySilentWithoutPermissionAndClearWhenTheRoomEnds() async throws {
        TripShareNoticeAlerts.center = alerts.center(allowed: false)
        try await openRoom()
        let friend = try await join("봄")
        let noticeID = ShareIdentifiers.itemID()
        _ = try await friend.write([.create(id: noticeID, content: .notice(ShareNoticeContent(text: "모이자", createdAt: 1_950_000_000_000, by: 2)), group: nil)])
        await waitUntil("띠") { self.store.view(tripID: self.tripID).map { !TripShareNoticeAlerts.pending(in: $0).isEmpty } == true }
        await waitUntil("알린 것으로 적음") { (TripShareNoticeAlerts.defaults.dictionary(forKey: TripShareNoticeAlerts.seenKey)?[self.roomID] as? [String: Int])?[noticeID] != nil }
        XCTAssertTrue(alerts.posted.isEmpty, "허용하지 않았으면 알림을 올리지 않는다(권한도 묻지 않는다)")

        // 순수 계산: 방이 끝나면 올린 알림을 모두 걷는다.
        let view = try XCTUnwrap(store.view(tripID: tripID))
        let seen = TripShareNoticeAlerts.plan(view: view, ended: false, seen: [:], now: .now)
        XCTAssertEqual(seen.post.map(\.identifier), [TripShareNoticeAlerts.identifier(noticeID)])
        let ended = TripShareNoticeAlerts.plan(view: view, ended: true, seen: seen.seen, now: .now)
        XCTAssertEqual(ended.cancel, [TripShareNoticeAlerts.identifier(noticeID), TripShareNoticeAlerts.dueIdentifier(noticeID)])
        XCTAssertTrue(ended.post.isEmpty)
        XCTAssertTrue(ended.seen.isEmpty)
        let locked = TripShareNoticeAlerts.content(seen.post[0], language: .korean, locked: true)
        XCTAssertFalse(locked.body.contains("모이자"), "잠금 중에는 공지 글을 알림에 싣지 않는다")
    }
}
