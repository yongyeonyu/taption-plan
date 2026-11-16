import Foundation

/// 서버의 오류 코드(규약 5절). 문구는 앱이 붙인다.
public enum ShareErrorCode: String, Sendable, CaseIterable {
    case invalidJSON = "invalid_json"
    case unauthorized
    case removed
    case ownerOnly = "owner_only"
    case wrongPassword = "wrong_password"
    case forbidden
    case notFound = "not_found"
    case noNotice = "no_notice"
    case noMember = "no_member"
    case methodNotAllowed = "method_not_allowed"
    case roomExists = "room_exists"
    case roomFull = "room_full"
    case rekeyRequired = "rekey_required"
    case epochMismatch = "epoch_mismatch"
    case conflict
    case ownerCannotLeave = "owner_cannot_leave"
    case tooLarge = "too_large"
    case itemTooLarge = "item_too_large"
    case badRequest = "bad_request"
    case badCipher = "bad_cipher"
    case duplicateID = "duplicate_id"
    case kindImmutable = "kind_immutable"
    case badExpiry = "bad_expiry"
    case tooManyLocks = "too_many_locks"
    case sameProof = "same_proof"
    case incomplete
    case locked
    case lockRequired = "lock_required"
    case settlementClosed = "settlement_closed"
    case upgradeRequired = "upgrade_required"
    case rateLimited = "rate_limited"
    case joinLocked = "join_locked"
    case joinIPLimit = "join_ip_limit"
    case roomDailyLimit = "room_daily_limit"
    case unavailable
    /// 소켓에서 모르는 `op`(서버 구현에만 있고 규약 표에는 없다).
    case unknownOp = "unknown_op"
    /// 이 판이 모르는 코드. 원래 글자는 `ShareServerError.rawCode`.
    case unknown
}

/// 오류 응답에 함께 오는 칸들(코드마다 일부만 온다).
public struct ShareErrorDetail: Decodable, Sendable, Equatable {
    public var error: String
    public var remaining: Int?
    public var retryAfter: Int?
    public var epoch: Int?
    public var rev: Int?
    public var limit: String?
    public var index: Int?
    public var kind: String?
    public var reason: String?
    public var locks: [ShareLock]?
    public var names: [String]?
    public var conflicts: [ShareConflict]?
    public var max: Int?
    public var missing: Int?
    public var extra: Int?
    public var now: Int?
    /// `loc_closed`일 때 서버의 기간 창.
    public var locWindow: ShareLocWindow?

    public init(error: String) { self.error = error }
}

public struct ShareServerError: Error, Sendable, Equatable {
    public let status: Int
    public let code: ShareErrorCode
    public let rawCode: String
    public let detail: ShareErrorDetail

    public init(status: Int, detail: ShareErrorDetail) {
        self.status = status
        self.detail = detail
        rawCode = detail.error
        code = ShareErrorCode(rawValue: detail.error) ?? .unknown
    }
}

/// 왜 지금 고칠 수 없는가.
public enum ShareReadOnlyReason: Sendable, Equatable {
    /// 인터넷이 없거나 서버에 닿지 않는다(1차 기본값: 보기만).
    case offline
    /// 비밀번호가 바뀌었다. 새 비밀번호로 `rekey`해야 한다.
    case needsRekey
    /// 나갔거나 내보내졌거나 방이 사라졌다.
    case ended
    /// 다른 기기의 연결로 바뀌었다. 다시 `start()`해야 한다.
    case replaced
    /// 아직 서버와 맞춰 보지 않았다(`start()` 전).
    case notStarted
    /// 더 새 판이 쓴 항목이다(읽기만).
    case newerVersion
    /// 주인이 정산을 마감했다.
    case settlementClosed
    /// 이 종류·항목을 고칠 권한이 없다(10절).
    case notAllowed
}

public enum ShareError: Error, Sendable, Equatable {
    case server(ShareServerError)
    /// 인터넷이 없다.
    case offline
    /// 그 밖의 전송 실패.
    case transport
    /// 소켓으로 보낸 뒤 응답을 받기 전에 끊겼다. 됐는지 모르므로 따라잡은 뒤 다시 본다.
    case interrupted
    case invalidResponse
    case crypto
    case readOnly(ShareReadOnlyReason)
    /// 주인만 하는 일인데 주인 열쇠가 없다.
    case ownerKeyMissing
    /// 잠근 뒤 크기가 서버 한도를 넘는다.
    case itemTooLarge
    case unknownItem
    /// 풀지 못한 항목이 있어 키 교체를 할 수 없다(주인이 먼저 지워야 한다).
    case unreadableItems([String])

    /// 서버 오류면 그 코드.
    public var serverCode: ShareErrorCode? {
        if case .server(let error) = self { return error.code }
        return nil
    }
}
