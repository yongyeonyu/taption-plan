import Foundation
import TaptionTripShare

/// 시험용 가짜 서버: 메모리 안의 방들. 규약(`docs/TRIP_SHARE_PROTOCOL.md`)의 요청·방송·잠금·권한·충돌을 흉내 낸다.
/// 실제 서버(`server/trip-relay/src/share.js`)를 줄여 옮긴 것이라 횟수 제한·크기 한도·입장 잠금은 없다.
/// 세션 여러 개를 `transport`로 붙여 서로의 방송을 받는 것까지 볼 수 있다.
public actor ShareFakeServer {
    public struct Call: Sendable, Equatable {
        /// HTTP 메서드, 소켓 열기는 `WS`, 소켓 요청은 `SOCKET`.
        public var method: String
        public var path: String
        public var query: [URLQueryItem]
        public var headers: [String: String]
        /// 소켓 요청이면 `op`.
        public var op: String?
        public var body: Data?
    }

    /// 받은 요청들(순서대로). 인터넷이 없을 때의 시도도 적힌다.
    public private(set) var calls: [Call] = []
    /// 서버 시계(1970년부터의 밀리초). 시험이 `advance`로 민다.
    public private(set) var now: Int
    private var offline = false
    private var socketsRefused = false
    private var changesPage = 200
    private var rooms: [String: Room] = [:]
    private var tokenCount = 0

    public init(now: Int = 1_900_000_000_000) {
        self.now = now
    }

    public nonisolated var transport: ShareFakeTransport { ShareFakeTransport(server: self) }

    // MARK: 시험이 만지는 것

    public func advance(milliseconds: Int) { now += milliseconds }

    /// 인터넷이 없는 것처럼: 모든 요청이 `offline`으로 실패하고 열린 소켓이 끊긴다.
    public func setOffline(_ value: Bool) {
        offline = value
        if value { dropSockets(code: 1006) }
    }

    /// 소켓만 안 되는 망(HTTP는 됨).
    public func setSocketsRefused(_ value: Bool) {
        socketsRefused = value
        if value { dropSockets(code: 1006) }
    }

    public func setChangesPage(_ value: Int) { changesPage = value }

    /// 모든 소켓을 이 코드로 닫는다(서버가 끊은 것처럼).
    public func dropSockets(code: Int) {
        for room in rooms.values {
            for socket in room.sockets {
                socket.shut(code: code)
                detach(socket, room: room)
            }
        }
    }

    public func socketCount(roomID: String) -> Int { rooms[roomID]?.sockets.count ?? 0 }
    public func rev(roomID: String) -> Int { rooms[roomID]?.rev ?? 0 }
    public func clearCalls() { calls = [] }

    /// 서버만 할 수 있는 장난: 항목의 암호문을 바꿔 놓는다(풀리지 않는 항목 시험).
    public func corrupt(roomID: String, itemID: String, cipher: String) {
        rooms[roomID]?.items[itemID]?.cipher = cipher
    }

    // MARK: 모델

    private final class Member {
        let no: Int
        let token: String
        var epoch: Int
        let joinedAt: Int
        var gone: String?

        init(no: Int, token: String, epoch: Int, joinedAt: Int) {
            self.no = no
            self.token = token
            self.epoch = epoch
            self.joinedAt = joinedAt
        }
    }

    private struct Item {
        var id: String
        var kind: String
        var rev: Int
        var seq: Int
        var epoch: Int
        var cipher: String?
        var group: String?
        var at: Int
        var by: Int
        var createdBy: Int
        var deleted = false
        var acks: [String: Int] = [:]

        var wire: [String: Any] {
            var out: [String: Any] = ["id": id, "kind": kind, "rev": rev, "seq": seq, "updatedAt": at, "by": by, "createdBy": createdBy]
            if deleted {
                out["deleted"] = true
                return out
            }
            out["epoch"] = epoch
            out["cipher"] = cipher ?? ""
            if let group { out["group"] = group }
            if kind == "notice" { out["acks"] = acks }
            return out
        }
    }

    private final class Room {
        let id: String
        var proof: String
        let ownerKey: String
        let createdAt: Int
        var expiresAt: Int
        var epoch = 1
        var rev = 0
        var closed = false
        var members: [Member] = []
        var nextNo = 2
        var locks: [String: (by: Int, until: Int)] = [:]
        var items: [String: Item] = [:]
        var sockets: [ShareFakeSocket] = []

        init(id: String, proof: String, ownerKey: String, createdAt: Int, expiresAt: Int) {
            self.id = id
            self.proof = proof
            self.ownerKey = ownerKey
            self.createdAt = createdAt
            self.expiresAt = expiresAt
        }

        var active: [Member] { members.filter { $0.gone == nil } }
    }

    private struct Reply {
        var status: Int
        var body: [String: Any]?
    }

    private static let kinds = ["plan", "expense-shared", "expense-own", "notice", "member", "meta"]
    private static let limits: [String: Int] = [
        "members": 10, "itemBytes": 4096, "liveItems": 1000, "roomBytes": 1_048_576, "batch": 50, "locksPerMember": 20, "leaseMs": 120_000,
    ]

    private func fail(_ status: Int, _ error: String, _ extra: [String: Any] = [:]) -> Reply {
        Reply(status: status, body: extra.merging(["error": error]) { $1 })
    }

    private func newToken() -> String {
        tokenCount += 1
        return ShareBytes.base64URL(Data(repeating: UInt8(tokenCount % 251), count: 31) + Data([UInt8(tokenCount / 251)]))
    }

    // MARK: HTTP

    func handle(_ request: ShareHTTPRequest) throws -> ShareHTTPResponse {
        calls.append(Call(method: request.method, path: request.path, query: request.query, headers: request.headers, op: nil, body: request.body))
        guard !offline else { throw ShareError.offline }
        let reply = route(request)
        let body = try reply.body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return ShareHTTPResponse(status: reply.status, headers: ["content-type": "application/json"], body: body)
    }

    private func route(_ request: ShareHTTPRequest) -> Reply {
        let parts = request.path.split(separator: "/").map(String.init)
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard parts.count >= 2, parts[0] == "share", parts[1] == "rooms" else { return fail(404, "not_found") }
        if parts.count == 2 {
            return request.method == "POST" ? create(body, headers: request.headers) : fail(405, "method_not_allowed")
        }
        let sub = parts.count > 3 ? parts[3] : ""
        guard let room = liveRoom(parts[2]) else { return fail(404, "not_found") }
        let op = "\(request.method) \(sub)"
        if op == "POST join" { return join(room, body) }
        let found = authenticate(room, request.headers)
        guard let me = found.member else { return found.reply ?? fail(401, "unauthorized") }
        if op == "POST rekey" { return rekey(room, me, body) }
        if op == "POST leave" { return me.no == 1 ? fail(409, "owner_cannot_leave") : remove(room, me, reason: "left") }
        guard me.epoch == room.epoch else { return fail(409, "rekey_required", ["epoch": room.epoch]) }
        switch op {
        case "GET ": return Reply(status: 200, body: describe(room, me))
        case "GET changes":
            let query = Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            return changes(room, since: Int(query["since"] ?? "0") ?? -1, limit: Int(query["limit"] ?? "200") ?? -1)
        case "POST items": return write(room, me, body, origin: nil)
        case "POST locks": return lock(room, me, body, origin: nil)
        case "POST acks": return ack(room, me, noticeID: body["id"] as? String, origin: nil)
        default: break
        }
        guard ["DELETE ", "POST kick", "POST close", "POST expiry", "POST rotate"].contains(op) else { return fail(404, "not_found") }
        guard me.no == 1, request.headers["x-share-owner"] == room.ownerKey else { return fail(403, "owner_only") }
        switch op {
        case "DELETE ":
            purge(room, reason: "deleted")
            return Reply(status: 204, body: nil)
        case "POST kick":
            guard let target = room.active.first(where: { $0.no == body["member"] as? Int }), target.no != 1 else { return fail(404, "no_member") }
            return remove(room, target, reason: "kicked")
        case "POST close":
            guard let closed = body["closed"] as? Bool else { return fail(422, "bad_request") }
            room.closed = closed
            roomEvent(room)
            return Reply(status: 200, body: ["closed": closed])
        case "POST expiry":
            guard let value = body["expiresAt"] as? Int, value >= now + 3_600_000, value <= room.createdAt + 400 * 86_400_000 else {
                return fail(422, "bad_expiry", ["max": room.createdAt + 400 * 86_400_000])
            }
            room.expiresAt = value
            roomEvent(room)
            return Reply(status: 200, body: ["expiresAt": value])
        default:
            return rotate(room, me, body)
        }
    }

    private func liveRoom(_ id: String) -> Room? {
        guard let room = rooms[id] else { return nil }
        guard now < room.expiresAt else {
            purge(room, reason: "expired")
            return nil
        }
        return room
    }

    private func authenticate(_ room: Room, _ headers: [String: String]) -> (member: Member?, reply: Reply?) {
        guard let header = headers["authorization"], header.hasPrefix("Bearer "),
              let member = room.members.first(where: { $0.token == String(header.dropFirst(7)) }) else { return (nil, fail(401, "unauthorized")) }
        if let gone = member.gone { return (nil, fail(403, "removed", ["reason": gone])) }
        return (member, nil)
    }

    private func create(_ body: [String: Any], headers: [String: String]) -> Reply {
        guard headers["authorization"]?.hasPrefix("Bearer ") == true else { return fail(401, "unauthorized") }
        guard let roomID = body["roomId"] as? String, ShareIdentifiers.isRoomID(roomID),
              let proof = body["proof"] as? String, ShareIdentifiers.isSecret(proof),
              let ownerKey = body["ownerKey"] as? String, ShareIdentifiers.isSecret(ownerKey), proof != ownerKey else { return fail(422, "bad_request") }
        guard let expiresAt = body["expiresAt"] as? Int, expiresAt >= now + 3_600_000, expiresAt <= now + 400 * 86_400_000 else {
            return fail(422, "bad_expiry", ["max": now + 400 * 86_400_000])
        }
        guard liveRoom(roomID) == nil else { return fail(409, "room_exists") }
        let room = Room(id: roomID, proof: proof, ownerKey: ownerKey, createdAt: now, expiresAt: expiresAt)
        let token = newToken()
        room.members.append(Member(no: 1, token: token, epoch: 1, joinedAt: now))
        rooms[roomID] = room
        return Reply(status: 201, body: ["roomId": roomID, "member": 1, "token": token, "epoch": 1, "rev": 0, "expiresAt": expiresAt, "limits": Self.limits])
    }

    private func join(_ room: Room, _ body: [String: Any]) -> Reply {
        guard let proof = body["proof"] as? String, ShareIdentifiers.isSecret(proof) else { return fail(422, "bad_request") }
        guard proof == room.proof else { return fail(403, "wrong_password", ["remaining": 4]) }
        guard room.active.count < 10 else { return fail(409, "room_full", ["limit": "members"]) }
        let member = Member(no: room.nextNo, token: newToken(), epoch: room.epoch, joinedAt: now)
        room.nextNo += 1
        room.members.append(member)
        broadcast(room, ["t": "member", "event": "join", "no": member.no, "now": now])
        return Reply(status: 201, body: [
            "roomId": room.id, "member": member.no, "token": member.token, "epoch": room.epoch, "rev": room.rev, "closed": room.closed,
            "expiresAt": room.expiresAt, "limits": Self.limits,
        ])
    }

    private func rekey(_ room: Room, _ me: Member, _ body: [String: Any]) -> Reply {
        guard body["proof"] as? String == room.proof else { return fail(403, "wrong_password", ["remaining": 4]) }
        me.epoch = room.epoch
        return Reply(status: 200, body: ["epoch": room.epoch, "rev": room.rev])
    }

    // MARK: 읽기

    private func liveLocks(_ room: Room) -> [[String: Any]] {
        room.locks = room.locks.filter { $0.value.until > now }
        return room.locks.sorted { $0.key < $1.key }.map { ["name": $0.key, "by": $0.value.by, "until": $0.value.until] }
    }

    private func describe(_ room: Room, _ me: Member) -> [String: Any] {
        let online = Set(room.sockets.map(\.member))
        let live = room.items.values.filter { !$0.deleted }
        return [
            "roomId": room.id, "you": me.no, "owner": 1, "epoch": room.epoch, "rev": room.rev, "closed": room.closed,
            "createdAt": room.createdAt, "expiresAt": room.expiresAt,
            "members": room.active.map { member -> [String: Any] in
                var out: [String: Any] = ["no": member.no, "joinedAt": member.joinedAt, "online": online.contains(member.no)]
                if member.epoch != room.epoch { out["stale"] = true }
                return out
            },
            "locks": liveLocks(room),
            "counts": ["items": live.count, "ids": room.items.count, "bytes": live.reduce(0) { $0 + ($1.cipher?.count ?? 0) * 3 / 4 }],
            "limits": Self.limits, "now": now,
        ]
    }

    private func changes(_ room: Room, since: Int, limit: Int) -> Reply {
        guard since >= 0, limit >= 1 else { return fail(422, "bad_request") }
        let page = min(limit, changesPage)
        let index = room.items.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        let taken = index.prefix(page)
        let more = taken.count < index.count
        let items = taken.filter { !(since == 0 && $0.deleted) }.map(\.wire)
        return Reply(status: 200, body: [
            "rev": room.rev, "epoch": room.epoch, "closed": room.closed, "items": items, "more": more,
            "next": more ? (taken.last?.seq ?? since) : room.rev,
        ])
    }

    // MARK: 잠금

    private func lockInfo(_ room: Room, _ name: String) -> [String: Any] {
        ["name": name, "by": room.locks[name]?.by ?? 0, "until": room.locks[name]?.until ?? 0]
    }

    private func blockers(_ room: Room, _ me: Member, _ name: String) -> [[String: Any]] {
        let theirs = { (lock: String) in room.locks[lock].map { $0.by != me.no } ?? false }
        var out: [[String: Any]] = []
        if theirs(name) { out.append(lockInfo(room, name)) }
        if name.hasPrefix("i:") {
            if let group = room.items[String(name.dropFirst(2))]?.group, theirs("g:" + group) { out.append(lockInfo(room, "g:" + group)) }
        } else {
            for held in room.locks.keys.sorted() where held.hasPrefix("i:") && theirs(held) {
                if room.items[String(held.dropFirst(2))]?.group == String(name.dropFirst(2)) { out.append(lockInfo(room, held)) }
            }
        }
        return out
    }

    private func lock(_ room: Room, _ me: Member, _ body: [String: Any], origin: ShareFakeSocket?) -> Reply {
        let acquire = body["acquire"] as? [String] ?? []
        let release = body["release"] as? [String] ?? []
        let wellFormed = { (name: String) in
            name.hasPrefix("i:") ? ShareIdentifiers.isItemID(String(name.dropFirst(2))) : name.hasPrefix("g:") && ShareIdentifiers.isGroupName(String(name.dropFirst(2)))
        }
        guard !(acquire + release).isEmpty, (acquire + release).allSatisfy(wellFormed) else { return fail(422, "bad_request") }
        _ = liveLocks(room)
        let blocked = acquire.flatMap { blockers(room, me, $0) }
        guard blocked.isEmpty else { return fail(423, "locked", ["locks": blocked, "now": now]) }
        let cleared = release.filter { room.locks[$0]?.by == me.no && !acquire.contains($0) }
        for name in cleared { room.locks[name] = nil }
        let until = now + 120_000
        for name in acquire { room.locks[name] = (me.no, until) }
        guard room.locks.values.filter({ $0.by == me.no }).count <= 20 else { return fail(422, "too_many_locks") }
        let set = acquire.map { ["name": $0, "by": me.no, "until": until] as [String: Any] }
        if !set.isEmpty || !cleared.isEmpty {
            broadcast(room, ["t": "locks", "set": set, "clear": cleared, "by": me.no, "now": now], except: origin)
        }
        return Reply(status: 200, body: ["locks": set, "released": cleared, "now": now])
    }

    private func dropLocks(_ room: Room, of no: Int, except origin: ShareFakeSocket? = nil) {
        let clear = room.locks.filter { $0.value.by == no }.map(\.key).sorted()
        guard !clear.isEmpty else { return }
        for name in clear { room.locks[name] = nil }
        broadcast(room, ["t": "locks", "set": [[String: Any]](), "clear": clear, "by": no, "now": now], except: origin)
    }

    // MARK: 쓰기

    private func denied(_ kind: String, _ me: Member, old: Item?, id: String, deleting: Bool, room: Room) -> Reply? {
        let mine = old == nil || old?.createdBy == me.no
        let extra: [String: Any] = ["kind": kind]
        switch kind {
        case "plan": return nil
        case "expense-shared": return room.closed ? fail(423, "settlement_closed", extra) : nil
        case "expense-own": return mine ? nil : fail(403, "forbidden", extra)
        case "notice": return mine || (deleting && me.no == 1) ? nil : fail(403, "forbidden", extra)
        case "member": return id == "member-\(me.no)" && !deleting ? nil : fail(403, "forbidden", extra)
        case "meta": return me.no == 1 ? nil : fail(403, "forbidden", extra)
        default: return fail(422, "bad_request")
        }
    }

    private func write(_ room: Room, _ me: Member, _ body: [String: Any], origin: ShareFakeSocket?) -> Reply {
        guard let writes = body["writes"] as? [[String: Any]], (1...50).contains(writes.count) else { return fail(422, "bad_request") }
        var seen: Set<String> = []
        for (index, write) in writes.enumerated() {
            guard let id = write["id"] as? String, ShareIdentifiers.isItemID(id), let baseRev = write["baseRev"] as? Int, baseRev >= 0 else {
                return fail(422, "bad_request", ["index": index])
            }
            if write["delete"] == nil {
                guard let kind = write["kind"] as? String, Self.kinds.contains(kind), (kind == "member") == id.hasPrefix("member-") else {
                    return fail(422, "bad_request", ["index": index])
                }
                guard let cipher = write["cipher"] as? String, cipher.hasPrefix("A"), cipher.count >= 39 else { return fail(422, "bad_cipher", ["index": index]) }
            } else if baseRev == 0 {
                return fail(422, "bad_request", ["index": index])
            }
            guard seen.insert(id).inserted else { return fail(422, "duplicate_id", ["index": index]) }
        }
        guard body["epoch"] as? Int == room.epoch else { return fail(409, "epoch_mismatch", ["epoch": room.epoch]) }
        _ = liveLocks(room)
        let mine = { (name: String) in room.locks[name]?.by == me.no }
        let theirs = { (name: String) in room.locks[name] != nil && !mine(name) }
        var conflicts: [[String: Any]] = []
        var blocked: [[String: Any]] = []
        var needed: [String] = []
        var groups: [String?] = []
        for (index, write) in writes.enumerated() {
            let id = write["id"] as? String ?? ""
            let baseRev = write["baseRev"] as? Int ?? 0
            let deleting = write["delete"] != nil
            let old = room.items[id]
            let creating = baseRev == 0
            if creating ? old != nil : (old == nil || old?.deleted == true || old?.rev != baseRev) {
                conflicts.append(["index": index, "id": id, "current": old.map { $0.wire as Any } ?? NSNull()])
                groups.append(nil)
                continue
            }
            if !creating, !deleting, write["kind"] as? String != old?.kind { return fail(422, "kind_immutable", ["index": index]) }
            let kind = old?.kind ?? (write["kind"] as? String ?? "")
            if var no = denied(kind, me, old: old, id: id, deleting: deleting, room: room) {
                no.body?["index"] = index
                return no
            }
            var nextGroup = old?.group
            if deleting { nextGroup = nil } else if write["group"] is NSNull { nextGroup = nil } else if let group = write["group"] as? String { nextGroup = group }
            groups.append(nextGroup)
            guard kind == "plan" || kind == "expense-shared" else { continue }
            let groupLocks = Set([old?.group, nextGroup].compactMap { $0 }).map { "g:" + $0 }.sorted()
            let held = ((creating ? [] : ["i:" + id]) + groupLocks).filter(theirs)
            if !held.isEmpty {
                blocked += held.map { lockInfo(room, $0) }
            } else if !creating, !mine("i:" + id), !(old?.group.map { mine("g:" + $0) } ?? false) {
                needed.append("i:" + id)
            }
        }
        if !blocked.isEmpty { return fail(423, "locked", ["locks": blocked, "now": now]) }
        if !needed.isEmpty { return fail(423, "lock_required", ["names": needed]) }
        if !conflicts.isEmpty { return fail(409, "conflict", ["conflicts": conflicts, "rev": room.rev]) }

        var done: [Item] = []
        for (write, group) in zip(writes, groups) {
            let id = write["id"] as? String ?? ""
            let old = room.items[id]
            room.rev += 1
            var item = Item(id: id, kind: old?.kind ?? (write["kind"] as? String ?? ""), rev: room.rev, seq: room.rev, epoch: room.epoch,
                            cipher: nil, group: nil, at: now, by: me.no, createdBy: old?.createdBy ?? me.no)
            if write["delete"] != nil {
                item.deleted = true
            } else {
                item.cipher = write["cipher"] as? String
                item.group = group
            }
            room.items[id] = item
            done.append(item)
        }
        broadcast(room, ["t": "items", "rev": room.rev, "items": done.map(\.wire)], except: origin)
        return Reply(status: 200, body: [
            "rev": room.rev,
            "items": done.map { ["id": $0.id, "rev": $0.rev, "seq": $0.seq, "updatedAt": $0.at] as [String: Any] },
        ])
    }

    private func ack(_ room: Room, _ me: Member, noticeID: String?, origin: ShareFakeSocket?) -> Reply {
        guard let id = noticeID, ShareIdentifiers.isItemID(id) else { return fail(422, "bad_request") }
        guard var item = room.items[id], !item.deleted, item.kind == "notice" else { return fail(404, "no_notice") }
        if item.acks[String(me.no)] == nil {
            room.rev += 1
            item.acks[String(me.no)] = now
            item.seq = room.rev
            room.items[id] = item
            broadcast(room, ["t": "ack", "id": id, "by": me.no, "at": now, "seq": item.seq, "rev": room.rev], except: origin)
        }
        return Reply(status: 200, body: ["id": id, "acks": item.acks, "seq": item.seq, "rev": room.rev])
    }

    // MARK: 나가기·주인

    private func remove(_ room: Room, _ member: Member, reason: String) -> Reply {
        member.gone = reason
        dropLocks(room, of: member.no)
        let cardID = "member-\(member.no)"
        if let card = room.items[cardID], !card.deleted {
            room.rev += 1
            let tomb = Item(id: cardID, kind: card.kind, rev: room.rev, seq: room.rev, epoch: card.epoch, cipher: nil, group: nil, at: now,
                            by: member.no, createdBy: card.createdBy, deleted: true)
            room.items[cardID] = tomb
            broadcast(room, ["t": "items", "rev": room.rev, "items": [tomb.wire]])
        }
        for socket in room.sockets where socket.member == member.no {
            bye(room, socket, reason: reason, code: reason == "kicked" ? 4000 : 1000)
        }
        broadcast(room, ["t": "member", "event": reason == "kicked" ? "kick" : "leave", "no": member.no, "now": now])
        return reason == "kicked" ? Reply(status: 200, body: ["ok": true, "member": member.no, "rekeyRecommended": true]) : Reply(status: 204, body: nil)
    }

    private func roomEvent(_ room: Room) {
        broadcast(room, ["t": "room", "closed": room.closed, "expiresAt": room.expiresAt, "epoch": room.epoch, "now": now])
    }

    private func rotate(_ room: Room, _ me: Member, _ body: [String: Any]) -> Reply {
        guard let rev = body["rev"] as? Int, let proof = body["proof"] as? String, ShareIdentifiers.isSecret(proof),
              let list = body["items"] as? [[String: Any]] else { return fail(422, "bad_request") }
        guard rev == room.rev else { return fail(409, "conflict", ["rev": room.rev]) }
        guard proof != room.proof else { return fail(422, "same_proof") }
        var fresh: [String: String] = [:]
        for entry in list {
            guard let id = entry["id"] as? String, let cipher = entry["cipher"] as? String, fresh[id] == nil else { return fail(422, "bad_request") }
            fresh[id] = cipher
        }
        let live = room.items.values.filter { !$0.deleted }.sorted { $0.seq < $1.seq }
        let missing = live.filter { fresh[$0.id] == nil }.count
        guard missing == 0, live.count == fresh.count else {
            return fail(422, "incomplete", ["missing": missing, "extra": fresh.count - (live.count - missing)])
        }
        room.epoch += 1
        for var item in live {
            room.rev += 1
            item.cipher = fresh[item.id]
            item.epoch = room.epoch
            item.rev = room.rev
            item.seq = room.rev
            room.items[item.id] = item
        }
        room.proof = proof
        room.locks = [:]
        me.epoch = room.epoch
        for socket in room.sockets {
            if socket.member == 1 {
                send(socket, ["t": "room", "closed": room.closed, "expiresAt": room.expiresAt, "epoch": room.epoch, "rekeyed": true, "now": now])
            } else {
                bye(room, socket, reason: "rekey", code: 4001)
            }
        }
        return Reply(status: 200, body: ["epoch": room.epoch, "rev": room.rev])
    }

    private func purge(_ room: Room, reason: String) {
        for socket in room.sockets { bye(room, socket, reason: reason, code: 4002) }
        rooms[room.id] = nil
    }

    // MARK: 소켓

    func open(path: String, headers: [String: String]) throws -> ShareFakeSocket {
        calls.append(Call(method: "WS", path: path, query: [], headers: headers, op: nil, body: nil))
        guard !offline else { throw ShareError.offline }
        guard !socketsRefused else { throw ShareError.transport }
        let parts = path.split(separator: "/").map(String.init)
        let socket = ShareFakeSocket(server: self, roomID: parts.count > 2 ? parts[2] : "")
        guard parts.count == 4, parts[3] == "ws", let room = liveRoom(parts[2]), let me = authenticate(room, headers).member, me.epoch == room.epoch else {
            // 실제로는 업그레이드가 거절된다. 기기에서는 닫힘 코드 없이 끊긴 것으로 보인다.
            socket.shut(code: 1006)
            return socket
        }
        socket.member = me.no
        let mine = room.sockets.filter { $0.member == me.no }
        if mine.count >= 2, let oldest = mine.first { bye(room, oldest, reason: "replaced", code: 4003) }
        let wasOnline = room.sockets.contains { $0.member == me.no }
        room.sockets.append(socket)
        send(socket, describe(room, me).merging(["t": "hello"]) { $1 })
        if !wasOnline { broadcast(room, ["t": "member", "event": "online", "no": me.no, "now": now], except: socket) }
        return socket
    }

    func socketMessage(_ socket: ShareFakeSocket, _ text: String) {
        if text == "ping" { return socket.push("pong") }
        guard let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return send(socket, ["t": "res", "id": NSNull(), "status": 400, "error": "invalid_json"])
        }
        calls.append(Call(method: "SOCKET", path: "", query: [], headers: [:], op: body["op"] as? String, body: Data(text.utf8)))
        guard let room = liveRoom(socket.roomID), let me = room.members.first(where: { $0.no == socket.member }), me.gone == nil else { return }
        guard me.epoch == room.epoch else { return bye(room, socket, reason: "rekey", code: 4001) }
        let reply: Reply
        switch body["op"] as? String {
        case "lock": reply = lock(room, me, body, origin: socket)
        case "write": reply = write(room, me, body, origin: socket)
        case "ack": reply = ack(room, me, noticeID: body["notice"] as? String, origin: socket)
        case "changes": reply = changes(room, since: body["since"] as? Int ?? 0, limit: body["limit"] as? Int ?? 200)
        case "state": reply = Reply(status: 200, body: describe(room, me))
        default: reply = fail(400, "unknown_op")
        }
        // 본문의 id(공지 확인)보다 요청 번호가 앞선다.
        send(socket, (reply.body ?? [:]).merging(["t": "res", "id": body["id"] ?? NSNull(), "status": reply.status]) { $1 })
    }

    /// 기기가 닫았다.
    func socketClosed(_ socket: ShareFakeSocket) {
        guard let room = rooms[socket.roomID] else { return }
        detach(socket, room: room)
    }

    /// 그 참여자의 마지막 연결이 끊기면 잠금을 모두 풀고 알린다.
    private func detach(_ socket: ShareFakeSocket, room: Room) {
        guard let index = room.sockets.firstIndex(where: { $0 === socket }) else { return }
        room.sockets.remove(at: index)
        guard !room.sockets.contains(where: { $0.member == socket.member }) else { return }
        dropLocks(room, of: socket.member)
        broadcast(room, ["t": "member", "event": "offline", "no": socket.member, "now": now])
    }

    private func send(_ socket: ShareFakeSocket, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.push(String(decoding: data, as: UTF8.self))
    }

    private func bye(_ room: Room, _ socket: ShareFakeSocket, reason: String, code: Int) {
        send(socket, ["t": "bye", "reason": reason])
        socket.shut(code: code)
        room.sockets.removeAll { $0 === socket }
    }

    private func broadcast(_ room: Room, _ message: [String: Any], except: ShareFakeSocket? = nil) {
        for socket in room.sockets where socket !== except { send(socket, message) }
    }
}

/// 가짜 서버로 가는 전송. 세션마다 하나씩 만들어도 같은 서버를 본다.
public struct ShareFakeTransport: ShareTransport {
    let server: ShareFakeServer

    public func send(_ request: ShareHTTPRequest) async throws -> ShareHTTPResponse {
        try await server.handle(request)
    }

    public func openSocket(path: String, headers: [String: String]) async throws -> any ShareSocket {
        try await server.open(path: path, headers: headers)
    }
}

/// 가짜 소켓. 서버가 넣은 글자를 기기가 꺼내 간다.
final class ShareFakeSocket: ShareSocket, @unchecked Sendable {
    private let server: ShareFakeServer
    let roomID: String
    /// 서버 액터 안에서만 만진다.
    var member = 0
    private let lock = NSLock()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed: ShareSocketClosed?

    init(server: ShareFakeServer, roomID: String) {
        self.server = server
        self.roomID = roomID
    }

    func send(_ text: String) async throws {
        guard !isClosed else { throw ShareError.transport }
        await server.socketMessage(self, text)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            switch take(or: continuation) {
            case .success(let text?): continuation.resume(returning: text)
            case .failure(let error): continuation.resume(throwing: error)
            case .success(nil): break
            }
        }
    }

    func close(code: Int) async {
        shut(code: code)
        await server.socketClosed(self)
    }

    private var isClosed: Bool {
        lock.withLock { closed != nil }
    }

    /// 쌓인 글자가 있으면 그것을, 닫혔으면 오류를, 아니면 기다리게 해 두고 nil.
    private func take(or continuation: CheckedContinuation<String, any Error>) -> Result<String?, ShareSocketClosed> {
        lock.withLock {
            if !queue.isEmpty { return .success(queue.removeFirst()) }
            if let closed { return .failure(closed) }
            waiter = continuation
            return .success(nil)
        }
    }

    func push(_ text: String) {
        let waiting: CheckedContinuation<String, any Error>? = lock.withLock {
            guard closed == nil else { return nil }
            guard let waiter else {
                queue.append(text)
                return nil
            }
            self.waiter = nil
            return waiter
        }
        waiting?.resume(returning: text)
    }

    /// 쌓인 글자는 마저 읽히고, 그다음 읽기가 닫힘으로 끝난다.
    func shut(code: Int) {
        let failure = ShareSocketClosed(code: code)
        let waiting: CheckedContinuation<String, any Error>? = lock.withLock {
            guard closed == nil else { return nil }
            closed = failure
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: failure)
    }
}
