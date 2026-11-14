import Foundation
import XCTest
@testable import TaptionTripShare

/// 규약 5~7절의 JSON 모양. 예시는 규약 문서와 서버 구현(`share.js`의 응답)에서 옮긴 것이고 값은 지어냈다.
final class ShareWireTests: XCTestCase {
    private let limits = #"{"members":10,"itemBytes":4096,"liveItems":1000,"roomBytes":1048576,"batch":50,"locksPerMember":20,"leaseMs":120000}"#
    private let cipher = "AWBhYmNkZWZnaGlqa8y-BEvmoHOTwbYdGRhFzHJvhkML2LsBanwbpFFVghXhBbASwAaF-w"

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func object(_ value: some Encodable) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
    }

    func testKindsAndLimitsMatchTheServer() {
        XCTAssertEqual(ShareKind.allCases.map(\.rawValue), ["plan", "expense-shared", "expense-own", "notice", "member", "meta"])
        XCTAssertEqual(ShareKind.allCases.filter(\.needsLock), [.plan, .expenseShared])
        XCTAssertEqual(ShareLimits.v1, ShareLimits(members: 10, itemBytes: 4096, liveItems: 1000, roomBytes: 1024 * 1024, batch: 50, locksPerMember: 20, leaseMs: 120_000))
        XCTAssertEqual(ShareConstants.bodyBytes, 65_536)
        XCTAssertEqual(ShareConstants.changesPage, 200)
        XCTAssertEqual(ShareConstants.lockRenewSeconds, 60)
    }

    func testCreateAndJoinResponses() throws {
        let created = try decode(ShareEntry.self, #"{"roomId":"AAECAwQFBgcICQoLDA0ODw","member":1,"token":"t","epoch":1,"rev":0,"expiresAt":1765000000000,"limits":\#(limits)}"#)
        XCTAssertEqual(created.member, 1)
        XCTAssertNil(created.closed)
        XCTAssertEqual(created.limits, .v1)
        let joined = try decode(ShareEntry.self, #"{"roomId":"AAECAwQFBgcICQoLDA0ODw","member":2,"token":"t","epoch":3,"rev":41,"closed":true,"expiresAt":1,"limits":\#(limits)}"#)
        XCTAssertEqual(joined.closed, true)
        XCTAssertEqual(joined.rev, 41)
    }

    func testRoomStateAndHello() throws {
        let body = #"""
        "roomId":"AAECAwQFBgcICQoLDA0ODw","you":2,"owner":1,"epoch":1,"rev":41,"closed":false,"createdAt":5,"expiresAt":9,
        "members":[{"no":1,"joinedAt":5,"online":true},{"no":2,"joinedAt":6,"online":false,"stale":true}],
        "locks":[{"name":"i:QEFCQ0RFRkdISUpLTE1OTw","by":1,"until":77}],
        "counts":{"items":12,"ids":14,"bytes":5310},"limits":\#(limits),"now":70
        """#
        let state = try decode(ShareRoomState.self, "{\(body)}")
        XCTAssertEqual(state.you, 2)
        XCTAssertEqual(state.members.map(\.stale), [nil, true])
        XCTAssertEqual(state.locks, [ShareLock(name: "i:QEFCQ0RFRkdISUpLTE1OTw", by: 1, until: 77)])
        XCTAssertEqual(state.counts, ShareCounts(items: 12, ids: 14, bytes: 5310))
        XCTAssertEqual(try ShareSocketMessage.parse(#"{"t":"hello",\#(body)}"#), .hello(state))
    }

    func testChangesWithItemTombstoneAndNotice() throws {
        let json = #"""
        {"rev":9,"epoch":1,"closed":false,"more":true,"next":7,"items":[
          {"id":"QEFCQ0RFRkdISUpLTE1OTw","kind":"plan","rev":7,"seq":7,"epoch":1,"cipher":"\#(cipher)","updatedAt":3,"by":2,"createdBy":1,"group":"g1"},
          {"id":"notice-0001","kind":"notice","rev":4,"seq":8,"epoch":1,"cipher":"\#(cipher)","updatedAt":3,"by":1,"createdBy":1,"acks":{"2":55}},
          {"id":"member-3","kind":"member","rev":9,"seq":9,"deleted":true,"updatedAt":4,"by":3,"createdBy":3}
        ]}
        """#
        let changes = try decode(ShareChanges.self, json)
        XCTAssertTrue(changes.more)
        XCTAssertEqual(changes.next, 7)
        XCTAssertEqual(changes.items[0].group, "g1")
        XCTAssertFalse(changes.items[0].isTombstone)
        XCTAssertEqual(changes.items[1].acks, ["2": 55])
        XCTAssertTrue(changes.items[2].isTombstone)
        XCTAssertNil(changes.items[2].cipher)
        XCTAssertNil(changes.items[2].epoch)
    }

    func testLockWriteAckAndOwnerResponses() throws {
        XCTAssertEqual(try decode(ShareLockResult.self, #"{"locks":[{"name":"g:abc","by":2,"until":9}],"released":["i:12345678"],"now":4}"#).released, ["i:12345678"])
        let written = try decode(ShareWriteResult.self, #"{"rev":12,"items":[{"id":"abcdefgh","rev":11,"seq":11,"updatedAt":1},{"id":"abcdefgi","rev":12,"seq":12,"updatedAt":1}]}"#)
        XCTAssertEqual(written.items.map(\.rev), [11, 12])
        XCTAssertEqual(try decode(ShareAckResult.self, #"{"id":"notice-0001","acks":{"1":5,"2":6},"seq":13,"rev":13}"#).acks, ["1": 5, "2": 6])
        XCTAssertEqual(try decode(ShareRekeyResult.self, #"{"epoch":2,"rev":30}"#), ShareRekeyResult(epoch: 2, rev: 30))
        XCTAssertEqual(try decode(ShareKickResult.self, #"{"ok":true,"member":3,"rekeyRecommended":true}"#).member, 3)
    }

    func testErrorBodiesAndCodes() throws {
        let cases: [(String, ShareErrorCode)] = [
            (#"{"error":"wrong_password","remaining":3}"#, .wrongPassword),
            (#"{"error":"join_locked","retryAfter":900}"#, .joinLocked),
            (#"{"error":"room_full","limit":"members"}"#, .roomFull),
            (#"{"error":"removed","reason":"kicked"}"#, .removed),
            (#"{"error":"rekey_required","epoch":2}"#, .rekeyRequired),
            (#"{"error":"forbidden","index":0,"kind":"meta"}"#, .forbidden),
            (#"{"error":"locked","locks":[{"name":"i:12345678","by":1,"until":9}],"now":3}"#, .locked),
            (#"{"error":"lock_required","names":["i:12345678"]}"#, .lockRequired),
            (#"{"error":"settlement_closed","index":0,"kind":"expense-shared"}"#, .settlementClosed),
            (#"{"error":"incomplete","missing":1,"extra":0}"#, .incomplete),
            (#"{"error":"bad_expiry","max":99}"#, .badExpiry),
            (#"{"error":"unknown_op"}"#, .unknownOp),
            (#"{"error":"something_new"}"#, .unknown),
        ]
        for (json, code) in cases {
            let error = ShareServerError(status: 400, detail: try decode(ShareErrorDetail.self, json))
            XCTAssertEqual(error.code, code, json)
        }
        let detail = try decode(ShareErrorDetail.self, cases[0].0)
        XCTAssertEqual(detail.remaining, 3)
        let conflict = try decode(ShareErrorDetail.self, #"""
        {"error":"conflict","rev":20,"conflicts":[
          {"index":0,"id":"abcdefgh","current":{"id":"abcdefgh","kind":"plan","rev":19,"seq":19,"epoch":1,"cipher":"\#(cipher)","updatedAt":1,"by":2,"createdBy":1}},
          {"index":1,"id":"abcdefgi","current":null},
          {"index":2,"id":"abcdefgj","current":{"id":"abcdefgj","kind":"plan","rev":20,"seq":20,"deleted":true,"updatedAt":1,"by":2,"createdBy":1}}
        ]}
        """#)
        XCTAssertEqual(conflict.conflicts?.map(\.current?.rev), [19, nil, 20])
        XCTAssertEqual(conflict.conflicts?[2].current?.isTombstone, true)
        // 문서의 표에 있는 코드는 모두 enum에 있다.
        let documented = ["invalid_json", "unauthorized", "removed", "owner_only", "wrong_password", "forbidden", "not_found", "no_notice", "no_member",
                          "method_not_allowed", "room_exists", "room_full", "rekey_required", "epoch_mismatch", "conflict", "owner_cannot_leave",
                          "too_large", "item_too_large", "bad_request", "bad_cipher", "duplicate_id", "kind_immutable", "bad_expiry", "too_many_locks",
                          "same_proof", "incomplete", "locked", "lock_required", "settlement_closed", "upgrade_required", "rate_limited", "join_locked",
                          "join_ip_limit", "room_daily_limit", "unavailable"]
        for code in documented { XCTAssertNotNil(ShareErrorCode(rawValue: code), code) }
    }

    func testSocketBroadcasts() throws {
        XCTAssertEqual(
            try ShareSocketMessage.parse(#"{"t":"items","rev":8,"items":[{"id":"member-3","kind":"member","rev":8,"seq":8,"deleted":true,"updatedAt":4,"by":3,"createdBy":3}]}"#),
            .items(ShareItemsEvent(rev: 8, items: [ShareWireItem(id: "member-3", kind: "member", rev: 8, seq: 8, epoch: nil, cipher: nil, deleted: true,
                                                               updatedAt: 4, by: 3, createdBy: 3, group: nil, acks: nil)]))
        )
        XCTAssertEqual(
            try ShareSocketMessage.parse(#"{"t":"locks","set":[{"name":"i:12345678","by":2,"until":9}],"clear":["g:abc"],"by":2,"now":5}"#),
            .locks(ShareLocksEvent(set: [ShareLock(name: "i:12345678", by: 2, until: 9)], clear: ["g:abc"], by: 2, now: 5))
        )
        XCTAssertEqual(
            try ShareSocketMessage.parse(#"{"t":"ack","id":"notice-0001","by":2,"at":6,"seq":14,"rev":14}"#),
            .ack(ShareAckEvent(id: "notice-0001", by: 2, at: 6, seq: 14, rev: 14))
        )
        for event in ["join", "leave", "kick", "online", "offline"] {
            guard case .member(let parsed) = try ShareSocketMessage.parse(#"{"t":"member","event":"\#(event)","no":3,"now":5}"#) else { return XCTFail(event) }
            XCTAssertEqual(parsed.event.rawValue, event)
            XCTAssertEqual(parsed.no, 3)
        }
        XCTAssertEqual(
            try ShareSocketMessage.parse(#"{"t":"room","closed":true,"expiresAt":9,"epoch":2,"now":5}"#),
            .room(ShareRoomEvent(closed: true, expiresAt: 9, epoch: 2, now: 5, rekeyed: nil))
        )
        XCTAssertEqual(
            try ShareSocketMessage.parse(#"{"t":"room","closed":false,"expiresAt":9,"epoch":2,"rekeyed":true,"now":5}"#),
            .room(ShareRoomEvent(closed: false, expiresAt: 9, epoch: 2, now: 5, rekeyed: true))
        )
        for reason in ["kicked", "left", "rekey", "deleted", "expired", "replaced"] {
            XCTAssertEqual(try ShareSocketMessage.parse(#"{"t":"bye","reason":"\#(reason)"}"#), .bye(ShareByeReason(rawValue: reason)))
        }
        XCTAssertEqual(try ShareSocketMessage.parse(#"{"t":"bye","reason":"new"}"#), .bye(nil))
        XCTAssertEqual(try ShareSocketMessage.parse("pong"), .pong)
        XCTAssertEqual(try ShareSocketMessage.parse(#"{"t":"future","x":1}"#), .unknown("future"))
        XCTAssertThrowsError(try ShareSocketMessage.parse("not json"))
    }

    func testSocketResponses() throws {
        guard case .response(let ok) = try ShareSocketMessage.parse(#"{"t":"res","id":12,"status":200,"locks":[{"name":"i:12345678","by":2,"until":9}],"released":[],"now":4}"#) else { return XCTFail() }
        XCTAssertEqual(ok.id, 12)
        XCTAssertEqual(try ok.decode(ShareLockResult.self).locks.first?.until, 9)

        // 공지 확인의 응답에는 공지 id가 없고 `id`는 요청 번호다.
        guard case .response(let acked) = try ShareSocketMessage.parse(#"{"t":"res","id":13,"status":200,"acks":{"2":6},"seq":14,"rev":14}"#) else { return XCTFail() }
        XCTAssertEqual(try acked.decode(ShareAckResult.self), ShareAckResult(acks: ["2": 6], seq: 14, rev: 14))

        guard case .response(let failed) = try ShareSocketMessage.parse(#"{"t":"res","id":14,"status":423,"error":"lock_required","names":["i:12345678"]}"#) else { return XCTFail() }
        XCTAssertThrowsError(try failed.decode(ShareWriteResult.self)) { error in
            guard case ShareError.server(let server) = error else { return XCTFail() }
            XCTAssertEqual(server.status, 423)
            XCTAssertEqual(server.code, .lockRequired)
            XCTAssertEqual(server.detail.names, ["i:12345678"])
        }
        guard case .response(let orphan) = try ShareSocketMessage.parse(#"{"t":"res","id":null,"status":400,"error":"invalid_json"}"#) else { return XCTFail() }
        XCTAssertNil(orphan.id)
    }

    func testCloseCodes() {
        XCTAssertEqual([4000, 4001, 4002, 4003, 1009, 1006].map(ShareSocketClose.init(code:)), [.kicked, .rekey, .gone, .replaced, .tooBig, .other(1006)])
    }

    func testRequestsEncodeLikeTheProtocol() throws {
        XCTAssertEqual(
            try object(ShareCreateRequest(roomID: "r", proof: "p", ownerKey: "o", expiresAt: 5)),
            ["roomId": "r", "proof": "p", "ownerKey": "o", "expiresAt": 5]
        )
        let writes = ShareWriteBody(epoch: 1, writes: [
            .put(id: "newitem1", kind: "plan", baseRev: 0, cipher: "A", group: .set("g1")),
            .put(id: "olditem1", kind: "plan", baseRev: 7, cipher: "B"),
            .put(id: "olditem2", kind: "plan", baseRev: 8, cipher: "C", group: .clear),
            .remove(id: "olditem3", baseRev: 9),
        ])
        XCTAssertEqual(try object(writes), [
            "epoch": 1,
            "writes": [
                ["id": "newitem1", "kind": "plan", "baseRev": 0, "cipher": "A", "group": "g1"],
                ["id": "olditem1", "kind": "plan", "baseRev": 7, "cipher": "B"],
                ["id": "olditem2", "kind": "plan", "baseRev": 8, "cipher": "C", "group": NSNull()],
                ["id": "olditem3", "baseRev": 9, "delete": true],
            ],
        ] as NSDictionary)
        XCTAssertEqual(
            try object(ShareSocketRequest(id: 12, op: "lock", body: ShareLockBody(acquire: ["i:12345678"], release: []))),
            ["id": 12, "op": "lock", "acquire": ["i:12345678"], "release": []]
        )
        XCTAssertEqual(try object(ShareSocketRequest(id: 13, op: "ack", body: ShareSocketAckBody(notice: "notice-0001"))), ["id": 13, "op": "ack", "notice": "notice-0001"])
        XCTAssertEqual(try object(ShareSocketRequest(id: 14, op: "state", body: ShareEmptyBody())), ["id": 14, "op": "state"])
        XCTAssertEqual(try object(ShareSocketRequest(id: 15, op: "changes", body: ShareChangesBody(since: 7, limit: nil))), ["id": 15, "op": "changes", "since": 7])
        XCTAssertEqual(
            try object(ShareRotateBody(rev: 3, proof: "p", items: [ShareRotateItem(id: "abcdefgh", cipher: "A")])),
            ["rev": 3, "proof": "p", "items": [["id": "abcdefgh", "cipher": "A"]]]
        )
    }

    func testBackoffDoublesToACap() {
        XCTAssertEqual((0...8).map { ShareBackoff.delay(attempt: $0) }, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(ShareBackoff.delay(attempt: 2, jitter: 1), 5)
        XCTAssertEqual(ShareBackoff.delay(attempt: -1), 1)
    }
}
