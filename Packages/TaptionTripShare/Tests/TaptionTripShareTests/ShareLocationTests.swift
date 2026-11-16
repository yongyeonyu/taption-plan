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
        do { try await guest.sendLocation(first); XCTFail("창이 없으면 거절") } catch ShareError.server(let error) { XCTAssertEqual(error.detail.error, "loc_closed") }

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

    func testMeetingPointIsSharedThroughTheRoomAndNeverDeleted() async throws {
        let room = try await TestRoom.make()
        let clock = TestClock()
        let owner = try await room.liveSession(room.owner, clock: clock)
        let guest = try await room.liveSession(try await room.join(), clock: clock)
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
