import Foundation
import XCTest
@testable import TaptionTripShare
import TaptionTripShareTesting

/// 동기 엔진: 두 세션을 가짜 서버에 붙여 따라잡기·방송·잠금·충돌·끊김·키 교체를 본다.
final class ShareSessionTests: XCTestCase {
    private func created(_ session: ShareRoomSession, _ title: String, group: String? = nil) async throws -> String {
        let id = ShareIdentifiers.itemID()
        let outcome = try await session.write([.create(id: id, content: plan(title), group: group)])
        XCTAssertEqual(outcome, .done)
        return id
    }

    func testCatchUpPagesThroughEverythingAndDecrypts() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        try await owner.publish(card: ShareMemberCard(name: "가을", color: "orange"))
        try await owner.publish(meta: ShareTripMeta(name: "봄 여행", startDay: "2031-05-05", endDay: "2031-05-09", currency: "KRW"))
        for index in 1...5 { _ = try await created(owner, "일정 \(index)") }
        let doomed = try await created(owner, "지울 일정")
        try await owner.lock(items: [doomed])
        try await owner.write([.delete(id: doomed)])

        await room.server.setChangesPage(2)
        await room.server.clearCalls()
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await guest.view().items.count == 7 }
        let view = await guest.view()
        XCTAssertEqual(view.titles, (1...5).map { "일정 \($0)" })
        XCTAssertEqual(view.meta?.name, "봄 여행")
        XCTAssertEqual(view.cards, [1: ShareMemberCard(name: "가을", color: "orange")])
        XCTAssertEqual(view.me, 2)
        XCTAssertFalse(view.isOwner)
        let serverRev = await room.server.rev(roomID: room.roomID)
        XCTAssertEqual(view.rev, serverRev)
        XCTAssertEqual(view.members.map(\.no), [1, 2])
        let pages = await room.server.calls.filter { $0.op == "changes" }.count
        XCTAssertGreaterThanOrEqual(pages, 4, "두 개씩 여러 쪽으로 받는다")
        let snapshot = await guest.snapshot()
        XCTAssertEqual(snapshot.cursor, serverRev)
    }

    func testBroadcastsReachTheOtherSession() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await owner.view().members.filter(\.online).count == 2 }

        let id = try await created(owner, "함께 볼 일정")
        try await eventually { await guest.item(id) != nil }
        let seen = await guest.item(id)
        var item = try XCTUnwrap(seen)
        XCTAssertEqual(item.content, plan("함께 볼 일정"))
        XCTAssertEqual(item.createdBy, 1)

        try await guest.lock(items: [id])
        try await guest.write([.update(id: id, content: plan("손님이 고친 일정"))])
        try await guest.unlock(items: [id])
        try await eventually { await owner.item(id)?.content == plan("손님이 고친 일정") }
        let edited = await owner.item(id)
        item = try XCTUnwrap(edited)
        XCTAssertEqual(item.by, 2)
        XCTAssertEqual(item.createdBy, 1)

        try await owner.lock(items: [id])
        try await owner.write([.delete(id: id)])
        try await eventually { await guest.item(id) == nil }
        let (ownerRev, guestRev, serverRev) = (await owner.view().rev, await guest.view().rev, await room.server.rev(roomID: room.roomID))
        XCTAssertEqual([ownerRev, guestRev], [serverRev, serverRev])
        // 붙을 때 한 번씩만 따라잡았고, 그 뒤로는 방송의 순번이 이어져 다시 부르지 않았다.
        let catchUps = await room.server.calls.filter { $0.op == "changes" || $0.path.hasSuffix("/changes") }.count
        XCTAssertEqual(catchUps, 2)
    }

    func testEventsStreamReportsChanges() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = room.session(room.owner, clock: clock)
        let collector = Task { () -> [ShareSessionEvent] in
            var seen: [ShareSessionEvent] = []
            for await event in owner.events {
                seen.append(event)
                if case .items = event { break }
            }
            return seen
        }
        await owner.start()
        try await eventually { await owner.view().status == .live }
        let id = try await created(owner, "일정")
        let seen = await collector.value
        XCTAssertEqual(seen.first, .status(.connecting))
        XCTAssertTrue(seen.contains(.status(.live)))
        XCTAssertTrue(seen.contains(.members))
        XCTAssertEqual(seen.last, .items(changed: [id], removed: []))
        let generation = await owner.view().generation
        XCTAssertGreaterThanOrEqual(generation, seen.count)
    }

    func testConflictHandsBackTheLatestCopy() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "첫 판")

        // 손님은 소켓이 안 되는 망: HTTP로만 붙어 방송을 못 받는다.
        await room.server.setSocketsRefused(true)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await guest.item(id) != nil }
        let other = room.client(room.owner)
        let newer = try ShareCipher.seal(try plan("주인이 먼저 고친 판").json(), key: room.keys.encKey,
                                         context: ShareItemContext(roomID: room.roomID, itemID: id, kind: "plan", epoch: 1))
        _ = try await other.lock(acquire: ["i:" + id])
        _ = try await other.write(epoch: 1, writes: [.put(id: id, kind: "plan", baseRev: 1, cipher: newer)])
        _ = try await other.lock(release: ["i:" + id])

        try await guest.lock(items: [id])
        let outcome = try await guest.write([.update(id: id, content: plan("손님의 늦은 판"))])
        guard case .conflict(let conflicts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(conflicts.map(\.id), [id])
        XCTAssertEqual(conflicts.first?.current?.content, plan("주인이 먼저 고친 판"))
        let local = await guest.item(id)
        XCTAssertEqual(local?.content, plan("주인이 먼저 고친 판"), "로컬 사본이 최신본으로 바뀐다")
        XCTAssertEqual(local?.rev, 2)

        // 최신본 위에서 다시 고치면 된다.
        let retry = try await guest.write([.update(id: id, content: plan("손님이 다시 고친 판"))])
        XCTAssertEqual(retry, .done)
        let posts = await room.server.calls.filter { $0.method == "POST" && $0.path.hasSuffix("/items") }.count
        XCTAssertGreaterThanOrEqual(posts, 2, "소켓이 없으면 HTTP로 쓴다")
    }

    func testBatchIsAllOrNothing() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let group = room.keys.groupName(day: "2031-05-06")
        let first = try await created(owner, "하나", group: group)
        let second = try await created(owner, "둘", group: group)
        let before = await room.server.rev(roomID: room.roomID)

        // 잠금 없이 순서를 바꾸려 하면 둘 다 안 바뀐다.
        let error = await assertServerError(.lockRequired) {
            try await owner.write([.update(id: first, content: plan("하나'")), .update(id: second, content: plan("둘'"))])
        }
        XCTAssertEqual(error?.detail.names?.sorted(), ["i:" + first, "i:" + second].sorted())
        var rev = await room.server.rev(roomID: room.roomID)
        XCTAssertEqual(rev, before)
        var titles = await owner.view().titles
        XCTAssertEqual(titles, ["둘", "하나"])

        // 묶음 잠금 하나로 그 날의 항목들을 한 번에.
        try await owner.lock(groups: [group])
        try await owner.write([.update(id: first, content: plan("하나'")), .update(id: second, content: plan("둘'"))])
        try await owner.unlock(groups: [group])
        rev = await room.server.rev(roomID: room.roomID)
        XCTAssertEqual(rev, before + 2)
        titles = await owner.view().titles
        XCTAssertEqual(titles, ["둘'", "하나'"])
        let item = await owner.item(first)
        XCTAssertEqual(item?.group, group)
    }

    func testLocksBlockOthersAndExpireByTheDeviceClock() async throws {
        let room = try await TestRoom.make()
        let ownerClock = TestClock(), guestClock = TestClock(nowMs: 1_900_000_000_000 - 7_000) // 손님 기기 시계는 7초 느리다.
        let owner = try await room.liveSession(room.owner, clock: ownerClock)
        let guest = try await room.liveSession(try await room.join(), clock: guestClock)
        let id = try await created(owner, "잠글 일정")
        try await eventually { await guest.item(id) != nil }

        try await owner.lock(items: [id])
        let serverNow = await room.server.now
        var mine = await owner.lockState(item: id)
        XCTAssertEqual(mine, .mine(until: serverNow + 120_000))
        try await eventually { await guest.lockState(item: id) == .other(by: 1, until: serverNow + 120_000) }

        let blocked = await assertServerError(.locked) { try await guest.lock(items: [id]) }
        XCTAssertEqual(blocked?.detail.locks?.map(\.by), [1])
        await assertServerError(.locked) { try await guest.write([.update(id: id, content: plan("끼어들기"))]) }

        // 서버가 따로 알리지 않아도 기한이 지나면 풀린 것으로 본다(기기 시계 + 서버와의 차이).
        guestClock.advance(milliseconds: 119_000)
        var seen = await guest.lockState(item: id)
        XCTAssertEqual(seen, .other(by: 1, until: serverNow + 120_000))
        guestClock.advance(milliseconds: 2_000)
        seen = await guest.lockState(item: id)
        XCTAssertEqual(seen, .free)
        let locks = await guest.view().locks
        XCTAssertEqual(locks, [])

        // 풀면 방송으로 바로 안다.
        try await owner.unlock(items: [id])
        mine = await owner.lockState(item: id)
        XCTAssertEqual(mine, .free)
        try await guest.lock(items: [id])
        try await eventually { await owner.lockState(item: id) == .other(by: 2, until: serverNow + 120_000) }
    }

    func testHeldLocksAreRenewedEverySixtySeconds() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "오래 고치는 일정")
        try await owner.lock(items: [id])
        try await eventually { clock.pending(.lockRenewal) == 1 }
        XCTAssertEqual(clock.requested(.lockRenewal), [60])

        await room.server.advance(milliseconds: 60_000)
        clock.advance(milliseconds: 60_000)
        await room.server.clearCalls()
        clock.release(.lockRenewal)
        try await eventually { await room.server.calls.filter { $0.op == "lock" }.count == 1 }
        let now = await room.server.now
        try await eventually { await owner.lockState(item: id) == .mine(until: now + 120_000) }

        // 풀면 더 연장하지 않는다.
        try await owner.unlock(items: [id])
        try await eventually { clock.pending(.lockRenewal) == 1 }
        await room.server.clearCalls()
        clock.release(.lockRenewal)
        try await Task.sleep(for: .milliseconds(50))
        let renewals = await room.server.calls.filter { $0.op == "lock" }.count
        XCTAssertEqual(renewals, 0)
        XCTAssertEqual(clock.pending(.lockRenewal), 0)
    }

    /// HTTP 요청 하나가 망 끊김으로 실패해 상태가 잠깐 offline이 되어도, 소켓으로 소식이 오면 다시 live이고
    /// 잡아 둔 잠금의 연장도 이어진다(TSR1117A01). 전에는 연장 차례가 그 사이에 오면 고리가 끝나 2분 뒤 잠금이 풀렸다.
    func testLockRenewalSurvivesABriefOfflineBlip() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "고치는 중인 일정")
        try await owner.lock(items: [id])
        try await eventually { clock.pending(.lockRenewal) == 1 }

        await room.server.failNextHTTP()
        await assertThrows(.offline) { try await owner.setSettlementClosed(true) }
        let blipped = await owner.view().status
        XCTAssertEqual(blipped, .offline)
        clock.release(.lockRenewal)
        try await eventually("상태가 흔들린 때 온 연장 차례에도 고리는 남는다") { clock.pending(.lockRenewal) == 1 }

        try await eventually { clock.pending(.ping) == 1 }
        clock.release(.ping)
        try await eventually("소켓으로 pong이 오면 서버에 닿는 것이다") { await owner.view().status == .live }

        await room.server.advance(milliseconds: 120_000)
        clock.advance(milliseconds: 120_000)
        await room.server.clearCalls()
        clock.release(.lockRenewal)
        try await eventually { await room.server.calls.filter { $0.op == "lock" }.count == 1 }
        let now = await room.server.now
        try await eventually { await owner.lockState(item: id) == .mine(until: now + 120_000) }
    }

    /// 소켓이 안 되는 망(HTTP만)에서 HTTP로 잡은 잠금은 다시 붙기를 시도할 때마다 지워지지 않는다(TSR1117A01).
    /// 서버는 마지막 소켓이 닫힐 때만 잠금을 푼다. 소켓을 열지 못한 시도는 아무것도 닫지 않았다.
    func testFailedSocketAttemptsKeepLocksTakenOverHTTP() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        await room.server.setSocketsRefused(true)
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "소켓 없이 고치는 일정")
        try await owner.lock(items: [id])
        try await eventually { clock.pending(.reconnect) == 1 && clock.pending(.lockRenewal) == 1 }
        clock.release(.reconnect)
        try await eventually { clock.requested(.reconnect).count == 2 && clock.pending(.reconnect) == 1 }
        let state = await owner.lockState(item: id)
        guard case .mine = state else { return XCTFail("다시 붙기 시도 뒤에도 내 잠금이어야 한다: \(state)") }

        await room.server.advance(milliseconds: 60_000)
        clock.advance(milliseconds: 60_000)
        await room.server.clearCalls()
        clock.release(.lockRenewal)
        try await eventually { await room.server.calls.filter { $0.path.hasSuffix("/locks") }.count == 1 }
    }

    func testOfflineIsReadOnlyAndReconnectsWithBackoff() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "끊기기 전 일정")
        try await owner.lock(items: [id])

        await room.server.setOffline(true)
        try await eventually { await owner.view().status == .offline }
        try await eventually { clock.pending(.reconnect) == 1 }
        XCTAssertEqual(clock.requested(.reconnect), [1])
        // 보기만: 로컬 사본은 그대로 보이고 쓰기·잠금은 서버에 가지 않고 실패한다.
        let view = await owner.view()
        XCTAssertEqual(view.titles, ["끊기기 전 일정"])
        XCTAssertFalse(view.canWrite)
        XCTAssertEqual(view.locks, [], "끊기면 내 잠금은 풀린 것으로 본다")
        await room.server.clearCalls()
        await assertThrows(.readOnly(.offline)) { try await owner.write([.create(plan("오프라인 쓰기"))]) }
        await assertThrows(.readOnly(.offline)) { try await owner.lock(items: [id]) }
        await assertThrows(.readOnly(.offline)) { try await owner.acknowledge(noticeID: id) }
        var calls = await room.server.calls.count
        XCTAssertEqual(calls, 0)

        // 아직 인터넷이 없으면 더 길게 기다린다: 1 → 2 → 4초.
        clock.release(.reconnect)
        try await eventually { clock.requested(.reconnect) == [1, 2] && clock.pending(.reconnect) == 1 }
        clock.release(.reconnect)
        try await eventually { clock.requested(.reconnect) == [1, 2, 4] && clock.pending(.reconnect) == 1 }
        let status = await owner.view().status
        XCTAssertEqual(status, .offline)

        // 그 사이 다른 사람이 쓴 것은 다시 붙으면서 받는다.
        await room.server.setOffline(false)
        let other = room.client(try await room.join())
        let late = ShareIdentifiers.itemID()
        let cipher = try ShareCipher.seal(try plan("끊긴 사이의 일정").json(), key: room.keys.encKey,
                                          context: ShareItemContext(roomID: room.roomID, itemID: late, kind: "plan", epoch: 1))
        _ = try await other.write(epoch: 1, writes: [.put(id: late, kind: "plan", baseRev: 0, cipher: cipher)])
        clock.release(.reconnect)
        try await eventually { await owner.view().status == .live }
        try await eventually { await owner.view().titles == ["끊기기 전 일정", "끊긴 사이의 일정"] }
        calls = await room.server.socketCount(roomID: room.roomID)
        XCTAssertEqual(calls, 1)
        let outcome = try await owner.write([.create(plan("다시 붙은 뒤"))])
        XCTAssertEqual(outcome, .done)
    }

    func testDroppedSocketReconnectsWithoutGoingOffline() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        await room.server.dropSockets(code: 1006)
        try await eventually { clock.pending(.reconnect) == 1 }
        // HTTP로 서버에 닿으므로 고칠 수 있다(소켓이 없으면 HTTP).
        var status = await owner.view().status
        XCTAssertEqual(status, .live)
        await room.server.clearCalls()
        _ = try await created(owner, "소켓 없이 쓴 일정")
        let posts = await room.server.calls.filter { $0.method == "POST" }.count
        XCTAssertEqual(posts, 1)
        clock.release(.reconnect)
        try await eventually { await room.server.socketCount(roomID: room.roomID) == 1 }
        status = await owner.view().status
        XCTAssertEqual(status, .live)
    }

    func testCloseCodesEndOrPauseTheSession() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let id = try await created(owner, "남는 일정")

        // 4000 내보내짐: 끝. 다시 붙지 않고 로컬 사본은 남는다.
        let kicked = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await kicked.item(id) != nil }
        let result = try await owner.kick(member: 2)
        XCTAssertTrue(result.rekeyRecommended)
        try await eventually { await kicked.view().status == .ended(.kicked) }
        try await eventually { await owner.view().members.map(\.no) == [1] }
        await assertThrows(.readOnly(.ended)) { try await kicked.write([.create(plan("내보내진 뒤"))]) }
        let kept = await kicked.view().titles
        XCTAssertEqual(kept, ["남는 일정"])
        await kicked.start()
        let still = await kicked.view().status
        XCTAssertEqual(still, .ended(.kicked))
        let stored = await kicked.snapshot()
        XCTAssertEqual(stored.ended, .kicked)

        // 4003 다른 연결로 바뀜: 멈추고, 앱이 다시 시작하면 붙는다.
        let replaced = try await room.liveSession(try await room.join(), clock: clock)
        await room.server.dropSockets(code: 4003)
        try await eventually { await replaced.view().status == .replaced }
        await assertThrows(.readOnly(.replaced)) { try await replaced.write([.create(plan("밀려난 뒤"))]) }
        XCTAssertEqual(clock.pending(.reconnect), 0, "스스로 다시 붙지 않는다")
        try await eventually { await owner.view().status == .replaced }
        await replaced.start()
        try await eventually { await replaced.view().status == .live }
    }

    func testDeletedRoomAndLeaveEndTheSession() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let leaver = try await room.liveSession(try await room.join(), clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await leaver.publish(card: ShareMemberCard(name: "먼저 가는 사람", color: "blue"))
        try await eventually { await guest.view().cards[2] != nil }

        await assertServerError(.ownerCannotLeave) { try await owner.leave() }
        try await leaver.leave()
        let left = await leaver.view().status
        XCTAssertEqual(left, .ended(.left))
        try await eventually { await guest.view().members.map(\.no) == [1, 3] }
        try await eventually { await guest.view().cards[2] == nil }

        try await owner.deleteRoom()
        let gone = await owner.view().status
        XCTAssertEqual(gone, .ended(.gone))
        try await eventually { await guest.view().status == .ended(.gone) }
        XCTAssertEqual(clock.pending(.reconnect), 0)
    }

    func testRotateThenRekey() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let joined = try await room.join()
        let guest = try await room.liveSession(joined, clock: clock)
        let id = try await created(owner, "비밀번호 바꾸기 전 일정")
        try await owner.publish(card: ShareMemberCard(name: "가을", color: "orange"))
        try await eventually { await guest.view().items.count == 2 }

        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")
        await assertServerError(.sameProof) { try await owner.rotate(to: room.keys) }
        await assertThrows(.readOnly(.notAllowed)) { try await guest.rotate(to: newKeys) }
        let rotated = try await owner.rotate(to: newKeys)
        XCTAssertEqual(rotated.epoch, 2)
        var view = await owner.view()
        XCTAssertEqual(view.epoch, 2)
        XCTAssertEqual(view.status, .live)
        XCTAssertEqual(view.items.map(\.epoch), [2, 2])
        XCTAssertEqual(view.titles, ["비밀번호 바꾸기 전 일정"])
        let serverRev = await room.server.rev(roomID: room.roomID)
        XCTAssertEqual(view.rev, serverRev)
        // 주인은 새 세대로 바로 쓴다.
        try await owner.lock(items: [id])
        try await owner.write([.update(id: id, content: plan("바꾼 뒤 일정"))])

        // 참여자: 4001 → 새 비밀번호를 받을 때까지 보기만.
        try await eventually { await guest.view().status == .needsRekey }
        await assertThrows(.readOnly(.needsRekey)) { try await guest.write([.create(plan("옛 키로 쓰기"))]) }
        XCTAssertEqual(clock.pending(.reconnect), 0)
        let wrong = await assertServerError(.wrongPassword) { try await guest.rekey(with: room.keys) }
        XCTAssertEqual(wrong?.detail.remaining, 4)
        let stuck = await guest.view().status
        XCTAssertEqual(stuck, .needsRekey)

        let rekeyed = try await guest.rekey(with: newKeys)
        XCTAssertEqual(rekeyed.epoch, 2)
        try await eventually { await guest.view().status == .live }
        try await eventually { await guest.view().titles == ["바꾼 뒤 일정"] }
        view = await guest.view()
        XCTAssertEqual(view.epoch, 2)
        XCTAssertEqual(view.unreadable, [])
        let outcome = try await guest.write([.create(plan("새 키로 쓴 일정"))])
        XCTAssertEqual(outcome, .done)
        try await eventually { await owner.view().titles == ["바꾼 뒤 일정", "새 키로 쓴 일정"] }

        // 옛 비밀번호로는 더 들어오지 못한다.
        await assertServerError(.wrongPassword) { try await room.join() }
    }

    /// 서버가 새 키를 받아 준 뒤의 따라잡기가 끊겨도 키 교체는 된 것이다(TSR1117A01): 새 세대를 돌려줘 앱이 새 뿌리 키를
    /// 키체인에 적을 수 있고, 인터넷이 돌아오면 연결 고리가 처음부터 받는다. 전에는 오류를 던져 새 키를 적지 못했다.
    func testRotationSucceedsEvenIfTheFollowingCatchUpDrops() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        await room.server.setSocketsRefused(true)
        let owner = try await room.liveSession(room.owner, clock: clock)
        _ = try await created(owner, "바꾸기 전 일정")
        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")

        await room.server.goOffline(afterResponseTo: "/rotate")
        let rotated = try await owner.rotate(to: newKeys)
        XCTAssertEqual(rotated.epoch, 2)
        let after = await owner.view()
        XCTAssertEqual(after.epoch, 2)
        XCTAssertEqual(after.status, .offline)
        XCTAssertEqual(after.titles, ["바꾸기 전 일정"], "로컬 사본은 그대로 보인다")

        await room.server.setOffline(false)
        await room.server.setSocketsRefused(false)
        try await eventually { clock.pending(.reconnect) == 1 }
        clock.release(.reconnect)
        try await eventually { await owner.view().status == .live }
        try await eventually { await owner.view().items.map(\.epoch) == [2] }
        let outcome = try await owner.write([.create(plan("바꾼 뒤 일정"))])
        XCTAssertEqual(outcome, .done)
    }

    /// 응답을 잃은 키 교체를 `confirmRotation`으로 확인한 뒤의 따라잡기가 끊겨도 true다(TSR1117A01). 전에는 오류를 던져
    /// 앱이 「됐는지 모름」으로 끝내고 새 뿌리 키를 적지 않았다.
    func testConfirmedRotationHoldsEvenIfTheFollowingCatchUpDrops() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        await room.server.setSocketsRefused(true)
        let owner = try await room.liveSession(room.owner, clock: clock)
        _ = try await created(owner, "바꾸기 전 일정")
        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")

        await room.server.failNextHTTP(pathSuffix: "/rotate", afterHandling: true)
        await assertThrows(.offline) { try await owner.rotate(to: newKeys) }
        await room.server.goOffline(afterResponseTo: room.roomID) // 상태 확인(GET <방>)에 답한 직후 끊긴다.
        let confirmed = try await owner.confirmRotation(with: newKeys)
        XCTAssertTrue(confirmed)
        let epoch = await owner.view().epoch
        XCTAssertEqual(epoch, 2)
    }

    /// 응답을 잃은 사이 소켓이 4001(또는 다른 세대의 `room`)을 받아 세션이 새 비밀번호를 기다리며 연결 고리를 멈췄어도,
    /// `confirmRotation`이 새 키로 넘어가면 고리를 다시 붙여 방송을 받는다(TSR1117A01).
    func testConfirmRotationRestartsTheConnectionLoop() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        _ = try await created(owner, "바꾸기 전 일정")
        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")

        await room.server.failNextHTTP(pathSuffix: "/rotate", afterHandling: true)
        await assertThrows(.offline) { try await owner.rotate(to: newKeys) }
        await room.server.dropSockets(code: 4001)
        try await eventually { await owner.view().status == .needsRekey }
        try await eventually { await room.server.socketCount(roomID: room.roomID) == 0 }

        let confirmed = try await owner.confirmRotation(with: newKeys)
        XCTAssertTrue(confirmed)
        try await eventually("고리가 다시 소켓을 붙인다") { await room.server.socketCount(roomID: room.roomID) == 1 }
        try await eventually { await owner.view().status == .live }
        try await eventually { await owner.view().items.map(\.epoch) == [2] }

        // 방송도 다시 받는다(새 비밀번호로 들어온 사람의 입장 소식).
        _ = try await ShareRoomClient.join(transport: room.server.transport, roomID: room.roomID, proof: newKeys.proof)
        try await eventually { await owner.view().members.map(\.no) == [1, 2] }
    }

    func testRekeyRequiredOverHTTPAlsoPausesTheSession() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        // 둘 다 소켓이 안 되는 망: 닫힘 코드(4001)를 받을 길이 없다.
        await room.server.setSocketsRefused(true)
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        _ = try await owner.rotate(to: try TestRoom.derive(room.invite, "새 비밀번호 2031"))
        let before = await guest.view().status
        XCTAssertEqual(before, .live)
        // 다음 요청의 409 `rekey_required`로 안다.
        await assertServerError(.rekeyRequired) { try await guest.catchUp() }
        let after = await guest.view().status
        XCTAssertEqual(after, .needsRekey)
    }

    func testUndecryptableItemsAreDroppedAndBlockRotationUnlessDiscarded() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let good = try await created(owner, "읽히는 일정")
        let bad = try await created(owner, "서버가 바꿔치기한 일정")
        // 다른 항목의 암호문을 옮겨 놓으면 AAD가 달라 풀리지 않는다.
        let moved = try ShareCipher.seal(try plan("옮겨 온 내용").json(), key: room.keys.encKey,
                                         context: ShareItemContext(roomID: room.roomID, itemID: good, kind: "plan", epoch: 1))
        await room.server.corrupt(roomID: room.roomID, itemID: bad, cipher: moved)

        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await guest.view().items.count == 1 }
        let view = await guest.view()
        XCTAssertEqual(view.titles, ["읽히는 일정"])
        XCTAssertEqual(view.unreadable.map(\.id), [bad])

        // 평문을 가진 기기(쓴 사람)는 그대로 보고, 새로 받는 기기는 풀지 못한다.
        let writerTitles = await owner.view().titles
        XCTAssertEqual(writerTitles.count, 2)
        await owner.stop()
        let fresh = try await room.liveSession(room.owner, clock: clock)
        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")
        await assertThrows(.unreadableItems([bad])) { try await fresh.rotate(to: newKeys) }
        let epoch = await fresh.view().epoch
        XCTAssertEqual(epoch, 1)
        let rotated = try await fresh.rotate(to: newKeys, discardingUnreadable: true)
        XCTAssertEqual(rotated.epoch, 2)
        let after = await fresh.view()
        XCTAssertEqual(after.titles, ["읽히는 일정"])
        XCTAssertEqual(after.unreadable.map(\.id), [bad])
    }

    func testSettlementCloseAndOwnership() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        let shared = ShareContent.sharedExpense(ShareExpenseContent(amount: 30_000, currency: "KRW", payer: .member(1), split: [.member(1), .member(2)], at: 1))
        let own = ShareContent.ownExpense(ShareOwnExpenseContent(amount: 4_000, currency: "KRW", at: 1))
        let sharedID = ShareIdentifiers.itemID(), ownID = ShareIdentifiers.itemID()
        try await owner.write([.create(id: sharedID, content: shared, group: nil), .create(id: ownID, content: own, group: nil)])
        try await eventually { await guest.view().items.count == 2 }

        // 개인(공개) 지출은 쓴 사람만. 서버에 가기 전에 막는다. meta는 주인만. 남의 카드는 못 쓴다.
        await room.server.clearCalls()
        await assertThrows(.readOnly(.notAllowed)) { try await guest.write([.update(id: ownID, content: own)]) }
        await assertThrows(.readOnly(.notAllowed)) { try await guest.write([.delete(id: ownID)]) }
        await assertThrows(.readOnly(.notAllowed)) { try await guest.publish(meta: ShareTripMeta(name: "n", startDay: "a", endDay: "b", currency: "KRW")) }
        await assertThrows(.readOnly(.notAllowed)) {
            try await guest.write([.create(id: ShareIdentifiers.memberCardID(1), content: .member(ShareMemberCard(name: "남", color: "c")), group: nil)])
        }
        await assertThrows(.readOnly(.notAllowed)) { try await guest.write([.update(id: sharedID, content: own)]) } // 종류는 못 바꾼다.
        await assertThrows(.unknownItem) { try await guest.write([.delete(id: ShareIdentifiers.itemID())]) }
        let calls = await room.server.calls.count
        XCTAssertEqual(calls, 0)

        // 마감하면 공유 지출이 잠긴다. 개인 지출·일정은 계속 쓸 수 있다.
        await assertThrows(.readOnly(.notAllowed)) { try await guest.rotate(to: room.keys) }
        await assertThrows(.ownerKeyMissing) { try await guest.setSettlementClosed(true) }
        try await owner.setSettlementClosed(true)
        try await eventually { await guest.view().closed }
        await assertThrows(.readOnly(.settlementClosed)) { try await guest.write([.create(shared)]) }
        await assertThrows(.readOnly(.settlementClosed)) { try await owner.write([.delete(id: sharedID)]) }
        let outcome = try await guest.write([.create(own), .create(plan("마감 뒤 일정"))])
        XCTAssertEqual(outcome, .done)
        try await owner.setSettlementClosed(false)
        try await eventually { await guest.view().closed == false }
        try await guest.lock(items: [sharedID])
        try await guest.write([.delete(id: sharedID)])
    }

    func testNoticeAcknowledgementsTravel() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        let id = ShareIdentifiers.itemID()
        let notice = ShareNoticeContent(text: "세 시까지 모여요", important: true, createdAt: clock.now)
        try await owner.write([.create(id: id, content: .notice(notice), group: nil)])
        try await eventually { await guest.item(id) != nil }

        await room.server.advance(milliseconds: 5_000)
        let at = await room.server.now
        try await guest.acknowledge(noticeID: id)
        try await guest.acknowledge(noticeID: id)
        let mine = await guest.item(id)
        XCTAssertEqual(mine?.acks, [2: at])
        try await eventually { await owner.item(id)?.acks == [2: at] }
        var revs = [await owner.view().rev, await guest.view().rev, await room.server.rev(roomID: room.roomID)]
        XCTAssertEqual(Set(revs).count, 1)
        let rev = await owner.item(id)?.rev
        XCTAssertEqual(rev, 1, "확인은 내용 개정을 올리지 않는다")

        // 공지를 고치면 확인이 비워진다.
        var edited = notice
        edited.text = "네 시로 바뀌었어요"
        try await owner.write([.update(id: id, content: .notice(edited))])
        try await eventually { await guest.item(id)?.acks == [:] }
        let cleared = await owner.item(id)?.acks
        XCTAssertEqual(cleared, [:])
        revs = [await owner.view().rev, await guest.view().rev, await room.server.rev(roomID: room.roomID)]
        XCTAssertEqual(Set(revs).count, 1)
    }

    func testGapInRevisionsTriggersCatchUp() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        await room.server.setSocketsRefused(true) // 둘 다 방송을 못 받는다.
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        _ = try await created(owner, "손님이 못 본 일정 1")
        _ = try await created(owner, "손님이 못 본 일정 2")
        let before = await guest.view().titles
        XCTAssertEqual(before, [])
        // 손님의 쓰기 응답이 rev 3인데 가진 것은 0: 사이가 비었으므로 따라잡는다.
        _ = try await created(guest, "손님의 일정")
        try await eventually { await guest.view().titles == ["손님의 일정", "손님이 못 본 일정 1", "손님이 못 본 일정 2"] }
        let rev = await guest.view().rev
        XCTAssertEqual(rev, 3)
    }

    func testSnapshotRestoresTheLocalCopyWithoutSecrets() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        try await owner.publish(card: ShareMemberCard(name: "가을", color: "orange"))
        let id = try await created(owner, "저장할 일정", group: room.keys.groupName(day: "2031-05-06"))
        let live = await owner.view()
        await owner.stop()
        let idle = await owner.view().status
        XCTAssertEqual(idle, .idle)

        // 저장: 앱이 준 폴더에. 키·토큰·주인 열쇠는 들어가지 않는다.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = ShareSnapshotDirectory(directory: folder)
        XCTAssertNil(store.snapshot(roomID: room.roomID))
        try await owner.persist(to: store)
        let text = try String(contentsOf: folder.appendingPathComponent(room.roomID + ".json"), encoding: .utf8)
        for secret in [room.owner.token, room.ownerKey, room.keys.proof, room.keys.root.base64EncodedString(), room.keys.encKey.base64EncodedString(),
                       ShareBytes.base64URL(room.invite.linkSecret), TestRoom.password] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("저장할 일정"), "평문이 들어 있으므로 앱이 보호된 위치에 둔다")

        // 복원: 비밀 저장소와 스냅샷 저장소를 넣어 연다. 인터넷이 없어도 보인다.
        let secrets = MemorySecretStore()
        let missing = try ShareRoomSession.open(roomID: room.roomID, transport: room.server.transport, secrets: secrets, snapshots: store)
        XCTAssertNil(missing, "비밀이 없으면 열지 않는다")
        try secrets.save(ShareRoomSecrets(root: room.keys.root, linkSecret: room.invite.linkSecret, token: room.owner.token, ownerKey: room.ownerKey,
                                          member: 1, epoch: 1), roomID: room.roomID)
        await room.server.setOffline(true)
        let reopened = try XCTUnwrap(try ShareRoomSession.open(roomID: room.roomID, transport: room.server.transport, secrets: secrets, snapshots: store,
                                                               environment: clock.environment))
        var view = await reopened.view()
        XCTAssertEqual(view.items, live.items)
        XCTAssertEqual(view.rev, live.rev)
        XCTAssertEqual(view.status, .idle)
        XCTAssertEqual(view.locks, [], "잠금은 저장하지 않는다")
        await assertThrows(.readOnly(.notStarted)) { try await reopened.write([.create(plan("시작 전 쓰기"))]) }

        // 다시 붙으면 저장한 순번 뒤만 받는다.
        await room.server.setOffline(false)
        let other = room.client(room.owner)
        _ = try await other.lock(acquire: ["i:" + id])
        _ = try await other.write(epoch: 1, writes: [.remove(id: id, baseRev: live.items.first { $0.id == id }?.rev ?? 0)])
        await room.server.clearCalls()
        await reopened.start()
        try await eventually { await reopened.view().titles == [] }
        view = await reopened.view()
        XCTAssertEqual(view.status, .live)
        XCTAssertEqual(view.cards[1]?.name, "가을")
        let sinces = await room.server.calls.filter { $0.op == "changes" }.compactMap { call -> Int? in
            (try? JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])?["since"] as? Int
        }
        XCTAssertEqual(sinces, [live.rev])
        try store.remove(roomID: room.roomID)
        XCTAssertNil(store.snapshot(roomID: room.roomID))
        await reopened.stop()
    }

    func testSnapshotFromAnOlderEpochResyncsFromTheStart() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let kept = try await created(owner, "남는 일정")
        let removed = try await created(owner, "사라질 일정")
        let old = await owner.snapshot()
        try await owner.lock(items: [removed])
        try await owner.write([.delete(id: removed)])
        let newKeys = try TestRoom.derive(room.invite, "새 비밀번호 2031")
        _ = try await owner.rotate(to: newKeys)
        await owner.stop()

        var entry = room.owner
        entry.epoch = 2
        let reopened = room.session(entry, clock: clock, keys: newKeys, snapshot: old)
        let before = await reopened.view().titles
        XCTAssertEqual(before, ["남는 일정", "사라질 일정"], "받기 전에는 옛 사본을 보여 준다")
        await reopened.start()
        try await eventually { await reopened.view().titles == ["남는 일정"] }
        let item = await reopened.item(kept)
        XCTAssertEqual(item?.epoch, 2)
    }

    func testOversizedItemIsRefusedBeforeSending() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        await room.server.clearCalls()
        let huge = ShareContent.plan(SharePlanContent(day: "2031-05-06", title: "큰 메모", memo: String(repeating: "가", count: 1_400)))
        await assertThrows(.itemTooLarge) { try await owner.write([.create(huge)]) }
        let calls = await room.server.calls.count
        XCTAssertEqual(calls, 0)
        // 한도 바로 아래는 패딩 없이라도 보낸다.
        let near = ShareContent.plan(SharePlanContent(day: "2031-05-06", title: "큰 메모", memo: String(repeating: "x", count: 3_990)))
        let outcome = try await owner.write([.create(near)])
        XCTAssertEqual(outcome, .done)
    }
}
