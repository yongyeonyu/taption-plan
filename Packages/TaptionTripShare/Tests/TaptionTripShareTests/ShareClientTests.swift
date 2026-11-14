import Foundation
import XCTest
@testable import TaptionTripShare
import TaptionTripShareTesting

/// `ShareRoomClient`가 규약의 경로·헤더·본문으로 보내는지, 소켓 우선·HTTP 대체가 맞는지. 서버는 가짜다.
final class ShareClientTests: XCTestCase {
    private func cipher(_ room: TestRoom, id: String, kind: String = "plan", epoch: Int = 1, title: String = "t") throws -> String {
        try ShareCipher.seal(ShareCipher.padded(try plan(title).json()), key: room.keys.encKey,
                             context: ShareItemContext(roomID: room.roomID, itemID: id, kind: kind, epoch: epoch))
    }

    func testCreateAndJoinSendSecretsOnlyInHeadersAndBody() async throws {
        let room = try await TestRoom.make()
        let joined = try await room.join()
        XCTAssertEqual(room.owner.member, 1)
        XCTAssertEqual(joined.member, 2)
        XCTAssertEqual(joined.closed, false)

        let calls = await room.server.calls
        XCTAssertEqual(calls.map(\.method), ["POST", "POST"])
        XCTAssertEqual(calls[0].path, "/share/rooms")
        XCTAssertEqual(calls[0].headers["authorization"], "Bearer " + TestRoom.appKey, "방 만들기만 앱 등록 키로")
        XCTAssertEqual(calls[1].path, "/share/rooms/\(room.roomID)/join")
        XCTAssertNil(calls[1].headers["authorization"], "입장은 인증 헤더 없이 증명만")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(calls[1].body)) as? [String: String])
        XCTAssertEqual(body, ["proof": room.keys.proof])
        // 링크 비밀 값·비밀번호·키는 어디로도 가지 않는다.
        let sent = calls.map { $0.path + String(decoding: $0.body ?? Data(), as: UTF8.self) }.joined()
        for secret in [ShareBytes.base64URL(room.invite.linkSecret), TestRoom.password, ShareBytes.base64URL(room.keys.encKey), ShareBytes.base64URL(room.keys.root)] {
            XCTAssertFalse(sent.contains(secret))
        }
    }

    func testJoinFailuresCarryTheirDetails() async throws {
        let room = try await TestRoom.make()
        let wrong = try TestRoom.derive(room.invite, "틀린 비밀번호")
        let error = await assertServerError(.wrongPassword) {
            try await ShareRoomClient.join(transport: room.server.transport, roomID: room.roomID, proof: wrong.proof)
        }
        XCTAssertEqual(error?.status, 403)
        XCTAssertEqual(error?.detail.remaining, 4)
        await assertServerError(.notFound) {
            try await ShareRoomClient.join(transport: room.server.transport, roomID: ShareIdentifiers.roomID(), proof: room.keys.proof)
        }
        await room.server.setOffline(true)
        await assertThrows(.offline) { try await room.join() }
    }

    func testRoomRequestsOverHTTP() async throws {
        let room = try await TestRoom.make()
        let client = room.client(room.owner)
        await room.server.clearCalls()
        let id = ShareIdentifiers.itemID()

        let state = try await client.state()
        XCTAssertEqual(state.you, 1)
        XCTAssertEqual(state.members.map(\.no), [1])
        guard case .done(let written) = try await client.write(epoch: 1, writes: [.put(id: id, kind: "plan", baseRev: 0, cipher: try cipher(room, id: id))]) else { return XCTFail() }
        XCTAssertEqual(written.rev, 1)
        let locked = try await client.lock(acquire: ["i:" + id])
        XCTAssertEqual(locked.locks.map(\.name), ["i:" + id])
        XCTAssertEqual(locked.locks.first?.until, locked.now + 120_000)
        let changes = try await client.changes(since: 0, limit: 10)
        XCTAssertEqual(changes.items.map(\.id), [id])
        XCTAssertEqual(changes.next, 1)
        XCTAssertFalse(changes.more)

        let calls = await room.server.calls
        let base = "/share/rooms/\(room.roomID)"
        XCTAssertEqual(calls.map { "\($0.method) \($0.path)" }, ["GET \(base)", "POST \(base)/items", "POST \(base)/locks", "GET \(base)/changes"])
        XCTAssertEqual(calls[3].query, [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "10")])
        for call in calls {
            XCTAssertEqual(call.headers["authorization"], "Bearer " + room.owner.token)
            XCTAssertNil(call.headers["x-share-owner"], "주인 열쇠는 주인만 하는 일에만 싣는다")
            XCTAssertFalse((call.path + call.query.map { $0.value ?? "" }.joined()).contains(room.owner.token), "토큰은 주소에 넣지 않는다")
        }
    }

    func testWriteConflictReturnsTheServerCopy() async throws {
        let room = try await TestRoom.make()
        let client = room.client(room.owner)
        let id = ShareIdentifiers.itemID()
        _ = try await client.write(epoch: 1, writes: [.put(id: id, kind: "plan", baseRev: 0, cipher: try cipher(room, id: id, title: "첫 판"))])
        _ = try await client.lock(acquire: ["i:" + id])
        _ = try await client.write(epoch: 1, writes: [.put(id: id, kind: "plan", baseRev: 1, cipher: try cipher(room, id: id, title: "둘째 판"))])

        // 예전 rev로 고치기 + 이미 있는 id로 만들기 + 없는 항목 지우기.
        let missing = ShareIdentifiers.itemID()
        let outcome = try await client.write(epoch: 1, writes: [
            .put(id: id, kind: "plan", baseRev: 1, cipher: try cipher(room, id: id, title: "늦은 판")),
            .remove(id: missing, baseRev: 5),
        ])
        guard case .conflict(let conflicts, let rev) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(rev, 2)
        XCTAssertEqual(conflicts.map(\.id), [id, missing])
        XCTAssertEqual(conflicts[0].current?.rev, 2)
        XCTAssertNil(conflicts[1].current)
        let plain = try XCTUnwrap(ShareCipher.open(try XCTUnwrap(conflicts[0].current?.cipher), key: room.keys.encKey,
                                                   context: ShareItemContext(roomID: room.roomID, itemID: id, kind: "plan", epoch: 1)))
        XCTAssertEqual(try ShareContent.decode(kind: "plan", json: plain), plan("둘째 판"))
        let serverRev = await room.server.rev(roomID: room.roomID)
        XCTAssertEqual(serverRev, 2, "전부 되거나 전부 안 된다")

        await assertServerError(.epochMismatch) { try await client.write(epoch: 9, writes: [.remove(id: id, baseRev: 2)]) }
    }

    func testSocketFirstThenHTTP() async throws {
        let room = try await TestRoom.make()
        let client = room.client(room.owner)
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        guard case .message(.hello(let hello)) = await iterator.next() else { return XCTFail("hello가 먼저 온다") }
        XCTAssertEqual(hello.members.first?.online, true)
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        await room.server.clearCalls()

        let id = ShareIdentifiers.itemID()
        guard case .done = try await client.write(epoch: 1, writes: [.put(id: id, kind: "plan", baseRev: 0, cipher: try cipher(room, id: id))]) else { return XCTFail() }
        _ = try await client.lock(acquire: ["i:" + id])
        _ = try await client.state()
        _ = try await client.changes(since: 0)
        var calls = await room.server.calls
        XCTAssertEqual(calls.map(\.method), Array(repeating: "SOCKET", count: 4))
        XCTAssertEqual(calls.map(\.op), ["write", "lock", "state", "changes"])
        // 소켓 요청에도 토큰은 싣지 않는다(연결할 때 헤더로만).
        XCTAssertFalse(calls.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains(room.owner.token) })

        // 주인 동작·rekey·나가기는 소켓이 열려 있어도 HTTP로.
        await room.server.clearCalls()
        let closed = try await client.setClosed(true)
        XCTAssertTrue(closed)
        calls = await room.server.calls
        XCTAssertEqual(calls.map(\.method), ["POST"])
        guard case .message(.room(let event)) = await iterator.next() else { return XCTFail("HTTP로 한 일은 내 소켓에도 방송된다") }
        XCTAssertTrue(event.closed)

        // 소켓이 닫히면 같은 호출이 HTTP로 간다.
        await client.disconnect()
        await room.server.clearCalls()
        _ = try await client.lock(acquire: ["i:" + id])
        calls = await room.server.calls
        XCTAssertEqual(calls.map { "\($0.method) \($0.path)" }, ["POST /share/rooms/\(room.roomID)/locks"])
        let sockets = await room.server.socketCount(roomID: room.roomID)
        XCTAssertEqual(sockets, 0)
    }

    func testSocketOpensWithTheTokenHeaderOnTheWsPath() async throws {
        let room = try await TestRoom.make()
        await room.server.clearCalls()
        let client = room.client(room.owner)
        _ = try await client.connect()
        let calls = await room.server.calls
        XCTAssertEqual(calls.map(\.method), ["WS"])
        XCTAssertEqual(calls[0].path, "/share/rooms/\(room.roomID)/ws")
        XCTAssertEqual(calls[0].headers, ["authorization": "Bearer " + room.owner.token])
        await client.disconnect()
    }

    func testOwnerActionsNeedTheOwnerKey() async throws {
        let room = try await TestRoom.make()
        let joined = try await room.join()
        let owner = room.client(room.owner)
        let guest = room.client(joined)
        let impostor = ShareRoomClient(transport: room.server.transport, roomID: room.roomID, token: joined.token, ownerKey: room.ownerKey)

        await assertThrows(.ownerKeyMissing) { try await guest.kick(member: 1) }
        await assertServerError(.ownerOnly) { try await impostor.setClosed(true) }
        await assertServerError(.ownerCannotLeave) { try await owner.leave() }

        await room.server.clearCalls()
        let now = await room.server.now
        let expiry = try await owner.setExpiry(now + 10 * 86_400_000)
        XCTAssertEqual(expiry, now + 10 * 86_400_000)
        await assertServerError(.badExpiry) { try await owner.setExpiry(now + 1) }
        let kicked = try await owner.kick(member: 2)
        XCTAssertTrue(kicked.rekeyRecommended)
        await assertServerError(.noMember) { try await owner.kick(member: 2) }
        let removed = await assertServerError(.removed) { try await guest.state() }
        XCTAssertEqual(removed?.detail.reason, "kicked")
        try await owner.deleteRoom()
        await assertServerError(.notFound) { try await owner.state() }

        let calls = await room.server.calls.filter { $0.headers["x-share-owner"] != nil }
        XCTAssertEqual(calls.map { "\($0.method) \($0.path.split(separator: "/").dropFirst(3).joined())" },
                       ["POST expiry", "POST expiry", "POST kick", "POST kick", "DELETE "])
        XCTAssertTrue(calls.allSatisfy { $0.headers["x-share-owner"] == room.ownerKey })
    }

    func testLeaveAckAndRekeyPaths() async throws {
        let room = try await TestRoom.make()
        let joined = try await room.join()
        let owner = room.client(room.owner)
        let guest = room.client(joined)
        let id = "notice-" + ShareIdentifiers.itemID()
        let notice = try ShareCipher.seal(Data(#"{"v":1,"text":"n","important":false,"createdAt":1}"#.utf8), key: room.keys.encKey,
                                          context: ShareItemContext(roomID: room.roomID, itemID: id, kind: "notice", epoch: 1))
        _ = try await owner.write(epoch: 1, writes: [.put(id: id, kind: "notice", baseRev: 0, cipher: notice)])
        await room.server.clearCalls()

        let first = try await guest.acknowledge(noticeID: id)
        let again = try await guest.acknowledge(noticeID: id)
        XCTAssertEqual(first.acks.keys.sorted(), ["2"])
        XCTAssertEqual(again, first, "여러 번 눌러도 처음 그대로")
        await assertServerError(.noNotice) { try await guest.acknowledge(noticeID: "not-a-notice") }
        let rekeyed = try await guest.rekey(proof: room.keys.proof)
        XCTAssertEqual(rekeyed.epoch, 1)
        try await guest.leave()
        await assertServerError(.removed) { try await guest.state() }

        let calls = await room.server.calls
        XCTAssertEqual(calls.map { "\($0.method) \($0.path.split(separator: "/").last ?? "")" },
                       ["POST acks", "POST acks", "POST acks", "POST rekey", "POST leave", "GET \(room.roomID)"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(calls[0].body)) as? [String: String], ["id": id])
    }

    func testURLSessionTransportBuildsAddressesFromTheInjectedBase() throws {
        let base = try XCTUnwrap(URL(string: "https://relay.example.invalid/v1/"))
        XCTAssertEqual(
            URLSessionShareTransport.url(base: base, path: "/share/rooms/abc/changes", query: [URLQueryItem(name: "since", value: "7")])?.absoluteString,
            "https://relay.example.invalid/v1/share/rooms/abc/changes?since=7"
        )
        XCTAssertEqual(URLSessionShareTransport.url(base: base, path: "/share/rooms/abc/ws", query: [], socket: true)?.absoluteString,
                       "wss://relay.example.invalid/v1/share/rooms/abc/ws")
        let local = try XCTUnwrap(URL(string: "http://localhost:8787"))
        XCTAssertEqual(URLSessionShareTransport.url(base: local, path: "/share/rooms", query: [], socket: true)?.absoluteString, "ws://localhost:8787/share/rooms")
        XCTAssertEqual(URLSessionShareTransport.shareError(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(URLSessionShareTransport.shareError(URLError(.badServerResponse)), .transport)
    }
}
