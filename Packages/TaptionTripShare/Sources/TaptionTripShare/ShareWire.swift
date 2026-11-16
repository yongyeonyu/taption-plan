import Foundation

// 규약의 요청·응답 모양(5~6절). 칸 이름은 서버의 JSON과 같다. 시각은 1970년부터의 밀리초(서버 시계).

/// 항목의 종류(10절). 서버는 이 여섯 가지만 받는다.
public enum ShareKind: String, Sendable, Codable, CaseIterable {
    case plan
    case expenseShared = "expense-shared"
    case expenseOwn = "expense-own"
    case notice
    case member
    case meta
    /// 모이는 곳(LOC1116S01). id는 `meet-point` 하나.
    case meet

    /// 고치기·지우기 전에 잠금을 잡아야 하는 종류(여럿이 고칠 수 있는 것).
    public var needsLock: Bool { self == .plan || self == .expenseShared }
}

/// 서버가 알려 주는 한도. 기기는 응답의 값을 쓰고, 받기 전에만 `v1`을 쓴다.
public struct ShareLimits: Codable, Sendable, Equatable {
    public var members: Int
    public var itemBytes: Int
    public var liveItems: Int
    public var roomBytes: Int
    public var batch: Int
    public var locksPerMember: Int
    public var leaseMs: Int

    public static let v1 = ShareLimits(members: 10, itemBytes: 4096, liveItems: 1000, roomBytes: 1_048_576, batch: 50, locksPerMember: 20, leaseMs: 120_000)
}

/// `limits`로 오지 않는 한도(13절).
public enum ShareConstants {
    public static let memberNumbers = 100
    public static let itemIDs = 3000
    public static let bodyBytes = 64 * 1024
    public static let rotateBodyBytes = 2 * 1024 * 1024
    public static let socketsPerMember = 2
    public static let changesPage = 200
    public static let locksLeaseSeconds = 120
    /// 고치는 동안 잠금을 다시 잡는 간격.
    public static let lockRenewSeconds: TimeInterval = 60
    public static let minimumLifeMs = 3_600_000
    public static let maximumLifeMs = 400 * 86_400_000
    public static let joinFailures = 5
}

public struct ShareMember: Codable, Sendable, Equatable {
    public var no: Int
    public var joinedAt: Int
    public var online: Bool
    /// 비밀번호가 바뀐 뒤 아직 `rekey`를 하지 않았다.
    public var stale: Bool?
}

public struct ShareLock: Codable, Sendable, Equatable {
    public var name: String
    public var by: Int
    public var until: Int
}

public struct ShareCounts: Codable, Sendable, Equatable {
    public var items: Int
    public var ids: Int
    public var bytes: Int
}

/// 방 만들기·입장의 응답. 만들기에는 `closed`가 없다.
public struct ShareEntry: Codable, Sendable, Equatable {
    public var roomId: String
    public var member: Int
    public var token: String
    public var epoch: Int
    public var rev: Int
    public var closed: Bool?
    public var expiresAt: Int
    public var limits: ShareLimits
}

/// 방 상태(6.3). 소켓의 `hello`도 같은 모양이다.
public struct ShareRoomState: Codable, Sendable, Equatable {
    public var roomId: String
    public var you: Int
    public var owner: Int
    public var epoch: Int
    public var rev: Int
    public var closed: Bool
    public var createdAt: Int
    public var expiresAt: Int
    public var members: [ShareMember]
    public var locks: [ShareLock]
    public var counts: ShareCounts
    public var limits: ShareLimits
    public var now: Int
    /// 위치를 보낼 수 있는 기간(주인이 정함). 아직 안 정했으면 nil.
    public var locWindow: ShareLocWindow?
    /// `hello`에만: 서버가 짧게 들고 있는 동행의 마지막 위치(암호문).
    public var locs: [ShareWireLocation]?
}

/// 서버가 주는 항목. 묘비는 `deleted`가 true이고 `epoch`·`cipher`가 없다.
public struct ShareWireItem: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var rev: Int
    public var seq: Int
    public var epoch: Int?
    public var cipher: String?
    public var deleted: Bool?
    public var updatedAt: Int
    public var by: Int
    public var createdBy: Int
    public var group: String?
    /// 공지에만. 참여자 번호(글자) → 확인한 시각.
    public var acks: [String: Int]?

    public var isTombstone: Bool { deleted == true }
}

public struct ShareChanges: Codable, Sendable, Equatable {
    public var rev: Int
    public var epoch: Int
    public var closed: Bool
    public var items: [ShareWireItem]
    public var more: Bool
    public var next: Int
}

public struct ShareLockResult: Codable, Sendable, Equatable {
    public var locks: [ShareLock]
    public var released: [String]
    public var now: Int
}

public struct ShareWriteReceipt: Codable, Sendable, Equatable {
    public var id: String
    public var rev: Int
    public var seq: Int
    public var updatedAt: Int
}

public struct ShareWriteResult: Codable, Sendable, Equatable {
    public var rev: Int
    public var items: [ShareWriteReceipt]
}

public struct ShareConflict: Codable, Sendable, Equatable {
    public var index: Int
    public var id: String
    /// 서버의 최신 항목(또는 묘비). 없던 항목이면 nil.
    public var current: ShareWireItem?
}

/// 쓰기의 결과. 충돌(409)은 오류가 아니라 최신본과 함께 돌려준다.
public enum ShareWriteOutcome: Sendable, Equatable {
    case done(ShareWriteResult)
    case conflict([ShareConflict], rev: Int)
}

/// 공지 확인의 응답. 소켓 응답에는 공지 id가 없으므로 넣지 않는다.
public struct ShareAckResult: Codable, Sendable, Equatable {
    public var acks: [String: Int]
    public var seq: Int
    public var rev: Int
}

public struct ShareRekeyResult: Codable, Sendable, Equatable {
    public var epoch: Int
    public var rev: Int
}

public struct ShareKickResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var member: Int
    public var rekeyRecommended: Bool
}

struct ShareClosedResult: Codable { var closed: Bool }
struct ShareExpiryResult: Codable { var expiresAt: Int }

// MARK: 요청

public struct ShareCreateRequest: Encodable, Sendable, Equatable {
    public var roomId: String
    public var proof: String
    public var ownerKey: String
    public var expiresAt: Int

    public init(roomID: String, proof: String, ownerKey: String, expiresAt: Int) {
        roomId = roomID
        self.proof = proof
        self.ownerKey = ownerKey
        self.expiresAt = expiresAt
    }
}

/// 고칠 때 묶음을 어떻게 할지: 그대로(칸을 뺌) / 묶음에서 뺌(`null`) / 이 묶음으로.
public enum ShareGroupChange: Sendable, Equatable {
    case keep
    case clear
    case set(String)
}

/// 쓰기 한 건(6.6).
public struct ShareWrite: Encodable, Sendable, Equatable {
    public var id: String
    public var kind: String?
    public var baseRev: Int
    public var cipher: String?
    public var group: ShareGroupChange
    public var delete: Bool

    /// 만들기(`baseRev` 0) 또는 고치기.
    public static func put(id: String, kind: String, baseRev: Int, cipher: String, group: ShareGroupChange = .keep) -> ShareWrite {
        ShareWrite(id: id, kind: kind, baseRev: baseRev, cipher: cipher, group: group, delete: false)
    }

    public static func remove(id: String, baseRev: Int) -> ShareWrite {
        ShareWrite(id: id, kind: nil, baseRev: baseRev, cipher: nil, group: .keep, delete: true)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, baseRev, cipher, group, delete }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseRev, forKey: .baseRev)
        if delete {
            try container.encode(true, forKey: .delete)
            return
        }
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(cipher, forKey: .cipher)
        switch group {
        case .keep: break
        case .clear: try container.encodeNil(forKey: .group)
        case .set(let name): try container.encode(name, forKey: .group)
        }
    }
}

/// 키 교체 때 다시 잠근 항목 하나(15절).
public struct ShareRotateItem: Codable, Sendable, Equatable {
    public var id: String
    public var cipher: String

    public init(id: String, cipher: String) {
        self.id = id
        self.cipher = cipher
    }
}

struct ShareProofBody: Encodable, Sendable { var proof: String }
struct ShareLocationBody: Encodable, Sendable { var epoch: Int; var cipher: String; var help: Bool }
struct ShareLocWindowBody: Encodable, Sendable { var from: Int; var until: Int }
struct ShareLocationList: Decodable, Sendable { var locs: [ShareWireLocation]; var locWindow: ShareLocWindow?; var now: Int }
struct ShareLocationAccepted: Decodable, Sendable { var now: Int }
struct ShareLockBody: Encodable, Sendable { var acquire: [String]; var release: [String] }
struct ShareWriteBody: Encodable, Sendable { var epoch: Int; var writes: [ShareWrite] }
struct ShareAckBody: Encodable, Sendable { var id: String }
struct ShareSocketAckBody: Encodable, Sendable { var notice: String }
struct ShareKickBody: Encodable, Sendable { var member: Int }
struct ShareClosedBody: Encodable, Sendable { var closed: Bool }
struct ShareExpiryBody: Encodable, Sendable { var expiresAt: Int }
struct ShareRotateBody: Encodable, Sendable { var rev: Int; var proof: String; var items: [ShareRotateItem] }
struct ShareChangesBody: Encodable, Sendable { var since: Int; var limit: Int? }
struct ShareEmptyBody: Encodable, Sendable {}
