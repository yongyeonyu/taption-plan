import Foundation
import XCTest
@testable import TaptionTripShare
import TaptionTripShareTesting

/// 여행 중 동행 위치(LOC1116S01): 평문·암호문·거리 계산과 두 세션의 왕복.
final class ShareLocationTests: XCTestCase {
    private let keys = ShareKeys(roomID: "AAECAwQFBgcICQoLDA0ODw", root: Data(repeating: 7, count: 32))

    private func payload(_ state: ShareLocationState = .ok, lat: Double? = 37.5665, lon: Double? = 126.978, at: Int = 1_765_000_000_000) -> ShareLocationPayload {
        ShareLocationPayload(state: state, latitude: lat, longitude: lon, accuracy: 12, at: at)
    }

    func testSealOpenRoundTripAndAADBinding() throws {
        let sealed = try ShareLocationSealer.seal(payload(), keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1)
        XCTAssertLessThanOrEqual(ShareBytes.data(base64URL: sealed)?.count ?? 999, 512, "서버 한도 512바이트 안")
        XCTAssertEqual(ShareLocationSealer.open(sealed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1), payload())
        // 다른 참여자·세대·방의 자리로 옮기면 풀리지 않는다.
        XCTAssertNil(ShareLocationSealer.open(sealed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 3, epoch: 1))
        XCTAssertNil(ShareLocationSealer.open(sealed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 2))
        XCTAssertNil(ShareLocationSealer.open(sealed, keys: keys, roomID: "oKGio6SlpqeoqaqrrK2urw", member: 2, epoch: 1))
    }

    func testSealedLocationMatchesTheFixedVector() throws {
        // 규약 21절의 시험 벡터: 같은 입력이면 같은 암호문이 나와야 서버·기기 구현이 어긋나지 않는다.
        let keys = ShareKeys(roomID: "AAECAwQFBgcICQoLDA0ODw", root: Data((0..<32).map { UInt8($0) }))
        let fixed = ShareLocationPayload(state: .ok, latitude: 37.5, longitude: 127.25, accuracy: 10, at: 1_765_000_000_000)
        let nonce = try XCTUnwrap(ShareBytes.data(hex: "606162636465666768696a6b"))
        let sealed = try ShareLocationSealer.seal(fixed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1, nonce: nonce)
        XCTAssertEqual(ShareItemContext(roomID: "AAECAwQFBgcICQoLDA0ODw", itemID: "loc-2", kind: "loc", epoch: 1).aad, "taption-share-v1|AAECAwQFBgcICQoLDA0ODw|loc-2|loc|1")
        XCTAssertEqual(ShareLocationSealer.open(sealed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1), fixed)
        print("LOC VECTOR enc=\(ShareBytes.hex(keys.encKey)) cipher=\(sealed)")
    }

    func testInvalidPayloadsAreNeverSealedOrAccepted() throws {
        XCTAssertThrowsError(try ShareLocationSealer.seal(payload(lat: 91), keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1))
        XCTAssertThrowsError(try ShareLocationSealer.seal(payload(lat: nil, lon: nil), keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1))
        XCTAssertThrowsError(try ShareLocationSealer.seal(payload(.hide), keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1), "숨김에는 좌표가 있으면 안 된다")
        XCTAssertNoThrow(try ShareLocationSealer.seal(payload(.hide, lat: nil, lon: nil), keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1))
        XCTAssertEqual(ShareLocationPayload(state: .help, latitude: 1, longitude: 2, at: 0, note: String(repeating: "가", count: 80)).note?.count, 40)
    }

    /// 도움 요청 메모는 40자여도 이모지처럼 큰 글자면 수백 바이트다. 잠근 뒤 서버 한도(512바이트)를 넘으면 늘 413이라
    /// 메모 끝을 덜어 한도 안에 넣는다(TSR1117A01).
    func testLongHelpNoteIsTrimmedToFitTheServerLimit() throws {
        let family = "👨‍👩‍👧‍👦"
        let help = ShareLocationPayload(state: .help, latitude: -33.123456789, longitude: 151.987654321, accuracy: 1234, at: 1_765_000_000_000,
                                        note: String(repeating: family, count: 60))
        XCTAssertEqual(help.note?.count, 40)
        XCTAssertGreaterThan(help.note?.utf8.count ?? 0, 512)
        let sealed = try ShareLocationSealer.seal(help, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1)
        XCTAssertLessThanOrEqual(ShareBytes.data(base64URL: sealed)?.count ?? 999, ShareLocationSealer.maxCipherBytes)
        let opened = try XCTUnwrap(ShareLocationSealer.open(sealed, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1))
        let note = try XCTUnwrap(opened.note)
        XCTAssertFalse(note.isEmpty)
        XCTAssertTrue(help.note?.hasPrefix(note) == true, "앞에서부터 글자 단위로 남긴다")
        XCTAssertEqual([opened.lat, opened.lon], [help.lat, help.lon])
        // 짧은 메모는 그대로.
        let short = ShareLocationPayload(state: .help, latitude: 1, longitude: 2, at: 0, note: "역 앞 출구 3번")
        let plain = try ShareLocationSealer.seal(short, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1)
        XCTAssertEqual(ShareLocationSealer.open(plain, keys: keys, roomID: "AAECAwQFBgcICQoLDA0ODw", member: 2, epoch: 1)?.note, "역 앞 출구 3번")
    }

    /// 모이는 곳을 해제하면 방에 남는 항목에 좌표·이름·시각이 남지 않는다(REV1117A01). 정한 사람만 둔다.
    func testClearedMeetingPointKeepsNoCoordinates() {
        let spot = ShareMeetContent(name: "역 앞", latitude: 35.68, longitude: 139.76, at: 1_800_000_000_000, by: 2)
        let cleared = spot.cleared
        XCTAssertFalse(cleared.on)
        XCTAssertEqual(cleared.lat, 0)
        XCTAssertEqual(cleared.lon, 0)
        XCTAssertEqual(cleared.name, "")
        XCTAssertNil(cleared.at)
        XCTAssertEqual(cleared.by, 2)
        XCTAssertTrue(cleared.isValid, "서버·세션의 검사를 그대로 통과한다")
    }

    func testDistanceWalkingTimeAndFreshness() {
        let seoul = (lat: 37.5665, lon: 126.9780), busan = (lat: 35.1796, lon: 129.0756)
        XCTAssertEqual(ShareLocationMath.distanceMeters(seoul, busan) / 1000, 325, accuracy: 3)
        XCTAssertEqual(ShareLocationMath.distanceMeters(seoul, seoul), 0, accuracy: 0.001)
        XCTAssertEqual(ShareLocationMath.walkingMinutes(meters: 10), 1)
        XCTAssertEqual(ShareLocationMath.walkingMinutes(meters: 750), 10)
        XCTAssertEqual(ShareLocationMath.minutesAgo(nowMs: 200_000, receivedAtMs: 100_000), 1)
        XCTAssertEqual(ShareLocationFreshness(ageMs: 60_000), .fresh)
        XCTAssertEqual(ShareLocationFreshness(ageMs: 6 * 60_000), .dim)
        XCTAssertEqual(ShareLocationFreshness(ageMs: 16 * 60_000), .old)
        XCTAssertEqual(ShareLocationFreshness(ageMs: 31 * 60_000), .lost)
    }

    /// 위치 오류(21.3절)도 이름 있는 코드다(TSR1117A01). 모르는 코드(`unknown`)로 떨어지면 앱이 거절·한도를 가리지 못한다.
    func testLocationErrorCodesAreNamed() {
        XCTAssertEqual(ShareErrorCode(rawValue: "loc_closed"), .locClosed)
        XCTAssertEqual(ShareErrorCode(rawValue: "loc_rate"), .locRate)
        var detail = ShareErrorDetail(error: "loc_rate")
        detail.retryAfter = 3
        XCTAssertEqual(ShareServerError(status: 429, detail: detail).code, .locRate)
    }

    func testSocketMessageParsing() throws {
        XCTAssertEqual(try ShareSocketMessage.parse(#"{"t":"loc","by":2,"off":true}"#), .loc(ShareWireLocation(by: 2, off: true)))
        guard case .loc(let wire) = try ShareSocketMessage.parse(#"{"t":"loc","by":3,"cipher":"AQ","epoch":1,"at":9,"help":true}"#) else { return XCTFail() }
        XCTAssertEqual([wire.by, wire.at, wire.epoch], [3, 9, 1])
        XCTAssertEqual(wire.help, true)
    }

    func testTwoSessionsExchangeLocationsAndOffClearsThem() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await owner.view().members.filter(\.online).count == 2 }

        // 기간 창이 없으면 서버가 거절하고 세션이 창을 안다.
        let first = payload()
        do { try await guest.sendLocation(first); XCTFail("창이 없으면 거절") } catch ShareError.server(let error) { XCTAssertEqual(error.code, .locClosed) }

        let now = await room.server.now
        try await owner.setLocationWindow(ShareLocWindow(from: now - 1000, until: now + 86_400_000))
        try await eventually { await guest.locationView().window != nil }
        do { try await guest.setLocationWindow(ShareLocWindow(from: 0, until: 1)); XCTFail("주인만") } catch {}

        try await guest.sendLocation(first)
        try await eventually { await owner.locationView().peers.count == 1 }
        let firstView = await owner.locationView()
        var peer = try XCTUnwrap(firstView.peers.first)
        XCTAssertEqual(peer.by, 2)
        XCTAssertEqual(peer.payload, first)
        let guestView = await guest.locationView()
        XCTAssertTrue(guestView.peers.isEmpty, "내 위치는 서버를 돌아오지 않는다")

        // 도움 요청.
        try await guest.sendLocation(ShareLocationPayload(state: .help, latitude: 37.1, longitude: 127.1, accuracy: 8, at: first.at + 1, note: "길을 잃었어요"))
        try await eventually { await owner.locationView().peers.first?.isHelp == true }
        let helpView = await owner.locationView()
        peer = try XCTUnwrap(helpView.peers.first)
        XCTAssertEqual(peer.payload.note, "길을 잃었어요")

        // 늦게 붙은 세 번째 기기는 hello로 마지막 위치를 바로 받는다.
        let third = try await room.liveSession(try await room.join(), clock: clock)
        try await eventually { await third.locationView().peers.map(\.by) == [2] }

        // 끄면 모두에게서 사라지고 서버도 지운다.
        try await guest.stopLocation()
        try await eventually { await owner.locationView().peers.isEmpty }
        let kept = await room.server.storedLocationMembers(roomID: room.roomID)
        XCTAssertEqual(kept, [])
    }

    /// 키 교체 직후 서버가 주인에게 보내는 `room`에도 기간 창이 실린다(TSR1117A01). 전에는 빠져 있어 주인 기기에서 창이 지워져 보였다.
    func testRotationKeepsTheLocationWindowOnTheOwner() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let now = await room.server.now
        let window = ShareLocWindow(from: now - 1000, until: now + 86_400_000)
        try await owner.setLocationWindow(window)
        _ = try await owner.rotate(to: try TestRoom.derive(room.invite, "새 비밀번호 2031"))
        // 소켓으로 쓴 것의 응답은 앞서 온 `room`보다 뒤에 읽힌다.
        _ = try await owner.write([.create(plan("교체 뒤 일정"))])
        let seen = await owner.locationView().window
        XCTAssertEqual(seen, window)

        // 창을 싣지 않던 예전 서버의 교체 알림도 창을 지우지 않는다. 보통 `room`의 null은 닫힘이다.
        let epoch = await owner.view().epoch
        await owner.receiveLocationWindow(ShareRoomEvent(closed: false, expiresAt: 0, epoch: epoch, now: now, rekeyed: true, locWindow: nil))
        let kept = await owner.locationView().window
        XCTAssertEqual(kept, window)
        await owner.receiveLocationWindow(ShareRoomEvent(closed: false, expiresAt: 0, epoch: epoch, now: now, rekeyed: nil, locWindow: nil))
        let closed = await owner.locationView().window
        XCTAssertNil(closed)
    }

    func testForeignOrBrokenCiphertextIsDropped() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        let now = await room.server.now
        await room.server.openLocationWindow(roomID: room.roomID, from: now - 1000, until: now + 86_400_000)
        // 다른 키로 잠근 위치는 풀리지 않아 화면에 나오지 않는다.
        let other = ShareKeys(roomID: room.roomID, root: Data(repeating: 9, count: 32))
        let sealed = try ShareLocationSealer.seal(payload(), keys: other, roomID: room.roomID, member: 2, epoch: 1)
        try await guest.client.sendLocation(epoch: 1, cipher: sealed, help: false)
        try await Task.sleep(for: .milliseconds(100))
        let leftover = await owner.locationView().peers
        XCTAssertTrue(leftover.isEmpty)
    }

    /// 가짜 서버가 실제 서버(`share.js`)의 위치 규칙을 따른다(TSR1117A01): 모이는 곳은 기간 창 안에서만, 위치는 크기·간격 한도,
    /// 보관 기한, 창 검사, 나가기·키 교체·창 밖으로 바꾸기에 지움. 전에는 모두 받아 시험이 실제와 다른 길을 탔다.
    func testFakeServerFollowsTheRealLocationRules() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guestEntry = try await room.join()
        let guest = try await room.liveSession(guestEntry, clock: clock)
        let spot = ShareMeetContent(name: "광장", latitude: 10, longitude: 20)
        let meet = ShareEdit.create(id: ShareMeetContent.itemID, content: .meet(spot), group: nil)
        await assertServerError(.locClosed) { try await guest.write([meet]) }

        let now = await room.server.now
        await assertServerError(.badRequest) { try await owner.setLocationWindow(ShareLocWindow(from: now, until: now + 41 * 86_400_000)) }
        try await owner.setLocationWindow(ShareLocWindow(from: now - 1000, until: now + 3_600_000))
        let placed = try await guest.write([meet])
        XCTAssertEqual(placed, .done)

        try await guest.sendLocation(payload())
        let tooSoon = await assertServerError(.locRate) { try await guest.sendLocation(payload()) }
        XCTAssertNotNil(tooSoon?.detail.retryAfter)
        try await guest.sendLocation(ShareLocationPayload(state: .help, latitude: 1, longitude: 2, at: 0)) // 도움 요청은 간격 밖
        let big = "AQ" + String(repeating: "A", count: 800)
        await assertServerError(.itemTooLarge) { try await guest.client.sendLocation(epoch: 1, cipher: big, help: true) }

        // 내보내면 그 사람의 위치가 지워진다.
        var kept = await room.server.storedLocationMembers(roomID: room.roomID)
        XCTAssertEqual(kept, [2])
        _ = try await owner.kick(member: 2)
        kept = await room.server.storedLocationMembers(roomID: room.roomID)
        XCTAssertEqual(kept, [])

        // 보통 위치는 10분 뒤 서버가 내주지 않는다.
        let other = try await room.liveSession(try await room.join(), clock: clock)
        try await other.sendLocation(payload())
        await room.server.advance(milliseconds: 11 * 60_000)
        await owner.refreshLocations()
        let stale = await owner.locationView().peers
        XCTAssertEqual(stale, [])

        // 키 교체는 옛 키로 잠근 위치를 버린다.
        await room.server.advance(milliseconds: 10_000)
        try await other.sendLocation(payload())
        _ = try await owner.rotate(to: try TestRoom.derive(room.invite, "새 비밀번호 2031"))
        kept = await room.server.storedLocationMembers(roomID: room.roomID)
        XCTAssertEqual(kept, [])

        // 창이 끝나면 모이는 곳은 다음 요청에서 거둔다(묘비).
        await room.server.advance(milliseconds: 3_600_000)
        try await owner.catchUp()
        let gone = await owner.item(ShareMeetContent.itemID)
        XCTAssertNil(gone)
    }

    func testMeetingPointIsSharedThroughTheRoomAndNeverDeleted() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
        let now = await room.server.now
        await room.server.openLocationWindow(roomID: room.roomID, from: now - 1000, until: now + 86_400_000)
        let spot = ShareMeetContent(name: "광장 시계탑", latitude: 37.5, longitude: 127.0, at: 1_765_000_000_000, by: 2)
        XCTAssertTrue(spot.isValid)
        let outcome = try await guest.write([.create(id: ShareMeetContent.itemID, content: .meet(spot), group: nil)])
        XCTAssertEqual(outcome, .done)
        try await eventually { await owner.item(ShareMeetContent.itemID) != nil }
        let seen = await owner.item(ShareMeetContent.itemID)
        XCTAssertEqual(seen?.content, .meet(spot))
        // 해제는 덮어쓰기로, 지우기는 막는다.
        var cleared = spot
        cleared.on = false
        try await owner.write([.update(id: ShareMeetContent.itemID, content: .meet(cleared))])
        do { try await owner.write([.delete(id: ShareMeetContent.itemID)]); XCTFail("지우기는 막힌다") } catch ShareError.readOnly(.notAllowed) {}
        XCTAssertFalse(ShareMeetContent(name: "x", latitude: 99, longitude: 0).isValid)
    }
}
