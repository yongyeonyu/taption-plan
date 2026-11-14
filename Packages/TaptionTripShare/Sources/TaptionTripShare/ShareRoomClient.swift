import Foundation

/// 방 하나에 대한 요청들(6·7절). 암호화는 하지 않는다(그것은 `ShareRoomSession`의 일).
/// 고치기·잠금·확인·따라잡기·상태는 소켓이 열려 있으면 소켓으로, 아니면 HTTP로 보낸다.
public actor ShareRoomClient {
    public nonisolated let roomID: String
    private let transport: any ShareTransport
    private let token: String
    private let ownerKey: String?
    private let socketTimeout: TimeInterval
    private var channel: ShareSocketChannel?

    static let roomsPath = "/share/rooms"

    /// - Parameters:
    ///   - token: 입장 때 받은 참여 토큰(키체인에서 꺼내 넣는다).
    ///   - ownerKey: 주인 기기만. 없으면 주인 동작이 `ownerKeyMissing`으로 실패한다.
    public init(transport: any ShareTransport, roomID: String, token: String, ownerKey: String? = nil, socketTimeout: TimeInterval = 15) {
        self.transport = transport
        self.roomID = roomID
        self.token = token
        self.ownerKey = ownerKey
        self.socketTimeout = socketTimeout
    }

    // MARK: 만들기·입장 (토큰이 생기기 전)

    /// 방 만들기. `appKey`는 앱 등록 키(기존 중계 서버의 주인 키)이고 이 요청에만 쓴다.
    public static func createRoom(transport: any ShareTransport, appKey: String, request: ShareCreateRequest) async throws -> ShareEntry {
        let http = ShareHTTPRequest(method: "POST", path: roomsPath, headers: bearer(appKey), body: try ShareJSON.data(request))
        return try decode(ShareEntry.self, from: try await transport.send(http))
    }

    /// 입장. 인증 헤더 없이 증명만 보낸다. 틀리면 `wrongPassword`(`remaining`), 잠기면 `joinLocked`(`retryAfter`).
    public static func join(transport: any ShareTransport, roomID: String, proof: String) async throws -> ShareEntry {
        let http = ShareHTTPRequest(method: "POST", path: "\(roomsPath)/\(roomID)/join", body: try ShareJSON.data(ShareProofBody(proof: proof)))
        return try decode(ShareEntry.self, from: try await transport.send(http))
    }

    // MARK: 소켓

    public var isConnected: Bool {
        get async { await channel?.isOpen ?? false }
    }

    /// 소켓을 연다. 붙자마자 `hello`가 오고, 닫히면 `.closed`가 온 뒤 흐름이 끝난다.
    public func connect() async throws -> AsyncStream<ShareSocketEvent> {
        await disconnect()
        let socket = try await transport.openSocket(path: roomPath("ws"), headers: Self.bearer(token))
        let channel = ShareSocketChannel(socket: socket, timeout: socketTimeout)
        self.channel = channel
        await channel.start()
        return channel.events
    }

    public func disconnect() async {
        await channel?.close()
        channel = nil
    }

    public func ping() async {
        await channel?.ping()
    }

    // MARK: 읽기

    public func state() async throws -> ShareRoomState {
        try await viaSocket("state", ShareEmptyBody(), retryOverHTTP: true) {
            try await self.http("GET", "", as: ShareRoomState.self)
        }
    }

    /// 따라잡기 한 쪽. `more`면 `since: next`로 다시 부른다.
    public func changes(since: Int, limit: Int? = nil) async throws -> ShareChanges {
        try await viaSocket("changes", ShareChangesBody(since: since, limit: limit), retryOverHTTP: true) {
            var query = [URLQueryItem(name: "since", value: String(since))]
            if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
            return try await self.http("GET", "changes", query: query, as: ShareChanges.self)
        }
    }

    // MARK: 쓰기·잠금·확인

    /// 전부 되거나 전부 안 된다. `baseRev` 충돌(409)은 서버의 최신본과 함께 `.conflict`로 돌려준다.
    public func write(epoch: Int, writes: [ShareWrite]) async throws -> ShareWriteOutcome {
        let body = ShareWriteBody(epoch: epoch, writes: writes)
        do {
            let result = try await viaSocket("write", body, retryOverHTTP: false) {
                try await self.http("POST", "items", body: body, as: ShareWriteResult.self)
            }
            return .done(result)
        } catch ShareError.server(let error) where error.code == .conflict && error.detail.conflicts != nil {
            return .conflict(error.detail.conflicts ?? [], rev: error.detail.rev ?? 0)
        }
    }

    /// 잡기(이미 내 것이면 2분 연장)와 풀기. 막히면 `locked`(`detail.locks`)를 던지고 아무것도 바뀌지 않는다.
    public func lock(acquire: [String] = [], release: [String] = []) async throws -> ShareLockResult {
        let body = ShareLockBody(acquire: acquire, release: release)
        return try await viaSocket("lock", body, retryOverHTTP: true) {
            try await self.http("POST", "locks", body: body, as: ShareLockResult.self)
        }
    }

    public func acknowledge(noticeID: String) async throws -> ShareAckResult {
        try await viaSocket("ack", ShareSocketAckBody(notice: noticeID), retryOverHTTP: true) {
            try await self.http("POST", "acks", body: ShareAckBody(id: noticeID), as: ShareAckResult.self)
        }
    }

    // MARK: 참여자 (HTTP만)

    public func leave() async throws {
        try await httpEmpty("POST", "leave")
        await disconnect()
    }

    /// 비밀번호가 바뀐 뒤 새 증명. 토큰은 그대로다. 성공하면 처음부터 따라잡는다.
    public func rekey(proof: String) async throws -> ShareRekeyResult {
        try await http("POST", "rekey", body: ShareProofBody(proof: proof), as: ShareRekeyResult.self)
    }

    // MARK: 주인만 (HTTP + 주인 열쇠)

    public func kick(member: Int) async throws -> ShareKickResult {
        try await http("POST", "kick", body: ShareKickBody(member: member), owner: true, as: ShareKickResult.self)
    }

    /// 정산 마감(true)·다시 열기(false). 돌려주는 값은 서버의 새 상태.
    public func setClosed(_ closed: Bool) async throws -> Bool {
        try await http("POST", "close", body: ShareClosedBody(closed: closed), owner: true, as: ShareClosedResult.self).closed
    }

    public func setExpiry(_ expiresAt: Int) async throws -> Int {
        try await http("POST", "expiry", body: ShareExpiryBody(expiresAt: expiresAt), owner: true, as: ShareExpiryResult.self).expiresAt
    }

    /// 키 교체(15절). `rev`가 최신이 아니면 `conflict`.
    public func rotate(rev: Int, proof: String, items: [ShareRotateItem]) async throws -> ShareRekeyResult {
        try await http("POST", "rotate", body: ShareRotateBody(rev: rev, proof: proof, items: items), owner: true, as: ShareRekeyResult.self)
    }

    /// 방을 통째로 지운다. 되돌릴 수 없다.
    public func deleteRoom() async throws {
        try await httpEmpty("DELETE", "", owner: true)
        await disconnect()
    }

    // MARK: 안쪽

    private func roomPath(_ sub: String) -> String {
        "\(Self.roomsPath)/\(roomID)" + (sub.isEmpty ? "" : "/" + sub)
    }

    private static func bearer(_ secret: String) -> [String: String] { ["authorization": "Bearer " + secret] }

    private func request(_ method: String, _ sub: String, query: [URLQueryItem], body: (any Encodable)?, owner: Bool) throws -> ShareHTTPRequest {
        var headers = Self.bearer(token)
        if owner {
            guard let ownerKey else { throw ShareError.ownerKeyMissing }
            headers["x-share-owner"] = ownerKey
        }
        return ShareHTTPRequest(method: method, path: roomPath(sub), query: query, headers: headers, body: try body.map { try ShareJSON.data($0) })
    }

    private func http<T: Decodable>(_ method: String, _ sub: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil, owner: Bool = false, as type: T.Type) async throws -> T {
        let response = try await transport.send(try request(method, sub, query: query, body: body, owner: owner))
        return try Self.decode(type, from: response)
    }

    private func httpEmpty(_ method: String, _ sub: String, owner: Bool = false) async throws {
        let response = try await transport.send(try request(method, sub, query: [], body: nil, owner: owner))
        if response.status >= 400 { throw Self.serverError(response) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: ShareHTTPResponse) throws -> T {
        guard response.status < 400 else { throw serverError(response) }
        return try ShareJSON.decode(type, from: response.body)
    }

    private static func serverError(_ response: ShareHTTPResponse) -> ShareError {
        var detail = (try? JSONDecoder().decode(ShareErrorDetail.self, from: response.body)) ?? ShareErrorDetail(error: "")
        if detail.retryAfter == nil, let header = response.headers["retry-after"] { detail.retryAfter = Int(header) }
        return .server(ShareServerError(status: response.status, detail: detail))
    }

    /// 소켓 우선. 보내지 못했으면 HTTP로, 보낸 뒤 끊겼으면 다시 해도 같은 일만 HTTP로 다시 한다.
    private func viaSocket<T: Decodable>(_ op: String, _ body: some Encodable & Sendable, retryOverHTTP: Bool, fallback: () async throws -> T) async throws -> T {
        guard let channel, await channel.isOpen else { return try await fallback() }
        do {
            return try await channel.request(op: op, body: body).decode(T.self)
        } catch ShareChannelError.unavailable {
            return try await fallback()
        } catch ShareChannelError.interrupted {
            guard retryOverHTTP else { throw ShareError.interrupted }
            return try await fallback()
        }
    }
}
