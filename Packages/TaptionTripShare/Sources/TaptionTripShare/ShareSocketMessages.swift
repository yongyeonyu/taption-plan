import Foundation

// 소켓 메시지(7절). 서버 → 기기는 `t`로 가른다.

public struct ShareItemsEvent: Codable, Sendable, Equatable {
    public var rev: Int
    public var items: [ShareWireItem]
}

public struct ShareLocksEvent: Codable, Sendable, Equatable {
    public var set: [ShareLock]
    public var clear: [String]
    public var by: Int
    public var now: Int
}

public struct ShareAckEvent: Codable, Sendable, Equatable {
    /// 공지 항목 id.
    public var id: String
    public var by: Int
    public var at: Int
    public var seq: Int
    public var rev: Int
}

public struct ShareMemberEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case join, leave, kick, online, offline }

    public var event: Kind
    public var no: Int
    public var now: Int
}

public struct ShareRoomEvent: Codable, Sendable, Equatable {
    public var closed: Bool
    public var expiresAt: Int
    public var epoch: Int
    public var now: Int
    /// 키 교체 직후 주인에게만 온다.
    public var rekeyed: Bool?
    /// 위치를 보낼 수 있는 기간. 없으면 닫힘.
    public var locWindow: ShareLocWindow?
}

public enum ShareByeReason: String, Codable, Sendable {
    case kicked, left, rekey, deleted, expired, replaced
}

/// 소켓 요청의 응답. 본문은 HTTP 응답과 같은 칸이라 원문을 들고 있다가 필요한 모양으로 읽는다.
public struct ShareSocketResponse: Sendable, Equatable {
    public var id: Int?
    public var status: Int
    public var raw: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard status < 400 else {
            let detail = (try? JSONDecoder().decode(ShareErrorDetail.self, from: raw)) ?? ShareErrorDetail(error: "")
            throw ShareError.server(ShareServerError(status: status, detail: detail))
        }
        return try ShareJSON.decode(type, from: raw)
    }
}

public enum ShareSocketMessage: Sendable, Equatable {
    case hello(ShareRoomState)
    case items(ShareItemsEvent)
    case locks(ShareLocksEvent)
    case ack(ShareAckEvent)
    case member(ShareMemberEvent)
    case room(ShareRoomEvent)
    case loc(ShareWireLocation)
    /// 모르는 이유면 nil.
    case bye(ShareByeReason?)
    case response(ShareSocketResponse)
    /// 글자 `pong`(JSON이 아님).
    case pong
    /// 이 판이 모르는 `t`. 무시한다.
    case unknown(String)

    private struct Head: Decodable {
        var t: String
        var id: Int?
        var status: Int?
        var reason: String?

        private enum CodingKeys: String, CodingKey { case t, id, status, reason }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            t = try container.decode(String.self, forKey: .t)
            id = try? container.decode(Int.self, forKey: .id) // 방송의 id는 글자(공지 id)일 수 있다.
            status = try? container.decode(Int.self, forKey: .status)
            reason = try? container.decode(String.self, forKey: .reason)
        }
    }

    public static func parse(_ text: String) throws -> ShareSocketMessage {
        if text == "pong" { return .pong }
        let data = Data(text.utf8)
        let head = try ShareJSON.decode(Head.self, from: data)
        switch head.t {
        case "hello": return .hello(try ShareJSON.decode(ShareRoomState.self, from: data))
        case "items": return .items(try ShareJSON.decode(ShareItemsEvent.self, from: data))
        case "locks": return .locks(try ShareJSON.decode(ShareLocksEvent.self, from: data))
        case "ack": return .ack(try ShareJSON.decode(ShareAckEvent.self, from: data))
        case "member": return .member(try ShareJSON.decode(ShareMemberEvent.self, from: data))
        case "room": return .room(try ShareJSON.decode(ShareRoomEvent.self, from: data))
        case "loc": return .loc(try ShareJSON.decode(ShareWireLocation.self, from: data))
        case "bye": return .bye(head.reason.flatMap(ShareByeReason.init(rawValue:)))
        case "res":
            guard let status = head.status else { throw ShareError.invalidResponse }
            return .response(ShareSocketResponse(id: head.id, status: status, raw: data))
        default: return .unknown(head.t)
        }
    }
}

/// 기기 → 서버 요청: `{ "id", "op", …본문의 칸 }`.
struct ShareSocketRequest<Body: Encodable & Sendable>: Encodable, Sendable {
    var id: Int
    var op: String
    var body: Body

    private enum CodingKeys: String, CodingKey { case id, op }

    func encode(to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(op, forKey: .op)
    }
}

/// 소켓이 닫힌 까닭(닫힘 코드).
public enum ShareSocketClose: Sendable, Equatable {
    /// 4000 내보내짐.
    case kicked
    /// 4001 비밀번호가 바뀜.
    case rekey
    /// 4002 방이 지워졌거나 기한이 지남.
    case gone
    /// 4003 같은 참여자의 다른 연결로 바뀜.
    case replaced
    /// 1009 너무 큰 메시지.
    case tooBig
    /// 그 밖(신호 끊김 포함). 다시 붙는다.
    case other(Int)

    public init(code: Int) {
        switch code {
        case 4000: self = .kicked
        case 4001: self = .rekey
        case 4002: self = .gone
        case 4003: self = .replaced
        case 1009: self = .tooBig
        default: self = .other(code)
        }
    }
}

public enum ShareSocketEvent: Sendable, Equatable {
    case message(ShareSocketMessage)
    case closed(ShareSocketClose)
}
