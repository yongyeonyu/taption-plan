import Foundation

/// 방과의 연결 상태. `.live`일 때만 고칠 수 있다.
public enum ShareSessionStatus: Sendable, Equatable {
    /// `start()` 전이거나 `stop()` 뒤.
    case idle
    case connecting
    /// 서버와 맞춰져 있다(소켓이 안 되면 HTTP로만).
    case live
    /// 인터넷이 없거나 서버에 닿지 않는다. 보기만 하고 스스로 다시 붙는다.
    case offline
    /// 비밀번호가 바뀌었다. 새 비밀번호로 `rekey`할 때까지 보기만.
    case needsRekey
    /// 같은 참여자의 다른 연결에 밀려났다. 다시 붙지 않는다(`start()`로만).
    case replaced
    /// 끝났다. 로컬 사본은 남는다.
    case ended(ShareEndReason)

    var isFinal: Bool {
        if case .ended = self { return true }
        return false
    }
}

public enum ShareEndReason: String, Sendable, Codable {
    case kicked
    case left
    /// 방이 지워졌거나 기한이 지났다.
    case gone
}

/// 세션이 내보내는 변화. 화면은 이것을 받고 `view()`를 다시 읽는다.
public enum ShareSessionEvent: Sendable, Equatable {
    case items(changed: [String], removed: [String])
    case locks
    case members
    /// 마감·기한·세대.
    case room
    case status(ShareSessionStatus)
    /// 방을 끝까지 받았다(처음부터든 이어서든). 이 순간의 로컬 사본에 없는 항목은 서버에도 없다.
    /// 연결만 된 때(`.status(.live)`)는 아직 덜 받았을 수 있으므로, 「방에 없으니 지운다」는 판단은 이것을 받은 뒤에만 한다.
    case caughtUp
}

/// 로컬 사본의 항목 하나(복호화된 내용).
public struct ShareLocalItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    /// 내용이 마지막으로 바뀐 때의 방 개정 번호. 고칠 때 `baseRev`로 보낸다.
    public var rev: Int
    public var seq: Int
    public var epoch: Int
    public var group: String?
    public var updatedAt: Int
    /// 마지막으로 고친 참여자(서버가 붙임).
    public var by: Int
    public var createdBy: Int
    /// 공지 확인: 참여자 번호 → 시각.
    public var acks: [Int: Int]
    /// 패딩 없는 평문 JSON. 키 교체 때 모르는 칸까지 그대로 다시 잠근다.
    public var json: String
    public var content: ShareContent

    public var isReadOnly: Bool { content.isReadOnly }
}

/// 한 항목의 잠금 상태(기기 시계로 판단).
public enum ShareLockState: Sendable, Equatable {
    case free
    case mine(until: Int)
    case other(by: Int, until: Int)
}

/// 풀지 못한 항목(키·세대가 다르거나 모양이 아님). 화면에 내지 않는다.
public struct ShareUnreadableItem: Sendable, Equatable, Codable {
    public var id: String
    public var kind: String
    public var rev: Int
    /// 받은 암호문 그대로(키 교체 때 버리기로 하면 이것을 다시 올려 자리만 지킨다).
    public var cipher: String?
}

/// 화면이 읽는 불변 값. `generation`은 무엇이든 바뀔 때마다 오른다.
public struct ShareRoomView: Sendable, Equatable {
    public var generation: Int
    public var status: ShareSessionStatus
    public var me: Int
    public var isOwner: Bool
    public var epoch: Int
    public var rev: Int
    /// 정산 마감.
    public var closed: Bool
    public var expiresAt: Int
    public var members: [ShareMember]
    /// 기한이 지나지 않은 잠금만.
    public var locks: [ShareLock]
    /// id 순.
    public var items: [ShareLocalItem]
    public var unreadable: [ShareUnreadableItem]
    public var limits: ShareLimits

    public var canWrite: Bool { status == .live }

    public func items(of kind: ShareKind) -> [ShareLocalItem] { items.filter { $0.kind == kind.rawValue } }

    public var meta: ShareTripMeta? {
        for item in items { if case .meta(let meta) = item.content { return meta } }
        return nil
    }

    /// 참여자 번호 → 카드.
    public var cards: [Int: ShareMemberCard] {
        var out: [Int: ShareMemberCard] = [:]
        for item in items { if case .member(let card) = item.content { out[item.createdBy] = card } }
        return out
    }
}

/// 고치기 한 건. 여러 건을 한 번에 보내면 전부 되거나 전부 안 된다.
public enum ShareEdit: Sendable, Equatable {
    /// `group`은 `ShareKeys.groupName(day:)`로 만든 묶음 이름.
    case create(id: String, content: ShareContent, group: String?)
    case update(id: String, content: ShareContent, group: ShareGroupChange)
    case delete(id: String)

    public static func create(_ content: ShareContent, group: String? = nil) -> ShareEdit {
        .create(id: ShareIdentifiers.itemID(), content: content, group: group)
    }

    public static func update(id: String, content: ShareContent) -> ShareEdit {
        .update(id: id, content: content, group: .keep)
    }

    public var id: String {
        switch self {
        case .create(let id, _, _), .update(let id, _, _), .delete(let id): id
        }
    }
}

/// 세션 쓰기의 결과. 충돌이면 로컬 사본은 이미 서버의 최신본으로 바뀌어 있다(화면을 바꾸고 다시 고치게 한다).
public enum ShareEditOutcome: Sendable, Equatable {
    case done
    case conflict([ShareEditConflict])
}

public struct ShareEditConflict: Sendable, Equatable {
    public var id: String
    /// 서버의 최신본(풀어서). 지워졌거나 풀지 못했으면 nil.
    public var current: ShareLocalItem?
}

// MARK: 저장

/// 로컬 사본의 스냅샷. 평문이 들어 있으므로 앱이 보호된 위치에 둔다. **키·토큰은 넣지 않는다.**
public struct ShareRoomSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var rev: Int
        public var seq: Int
        public var epoch: Int
        public var group: String?
        public var updatedAt: Int
        public var by: Int
        public var createdBy: Int
        public var acks: [String: Int]
        public var json: String
    }

    public static let currentFormat = 1

    public var format = ShareRoomSnapshot.currentFormat
    public var roomID: String
    public var me: Int
    public var epoch: Int
    public var rev: Int
    /// 반영한 마지막 순번(9절).
    public var cursor: Int
    public var closed: Bool
    public var expiresAt: Int
    public var members: [ShareMember]
    public var items: [Item]
    public var unreadable: [ShareUnreadableItem]
    public var limits: ShareLimits
    public var ended: ShareEndReason?

    /// 앱이 정한 위치에 쓴다(한 번에 바꿔 쓰기).
    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// 없거나 모양이 다르면 nil(처음부터 따라잡으면 된다).
    public static func read(from url: URL) -> ShareRoomSnapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(ShareRoomSnapshot.self, from: data),
              snapshot.format == currentFormat else { return nil }
        return snapshot
    }
}

/// 스냅샷을 두는 곳. 위치·보호 수준은 앱이 정해 넣는다.
public protocol ShareSnapshotStore: Sendable {
    func snapshot(roomID: String) -> ShareRoomSnapshot?
    func save(_ snapshot: ShareRoomSnapshot) throws
    func remove(roomID: String) throws
}

/// 앱이 준 폴더에 방마다 파일 하나(`<roomId>.json`)로 둔다.
public struct ShareSnapshotDirectory: ShareSnapshotStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(_ roomID: String) -> URL { directory.appendingPathComponent(roomID + ".json") }

    public func snapshot(roomID: String) -> ShareRoomSnapshot? {
        guard ShareIdentifiers.isRoomID(roomID) else { return nil }
        return ShareRoomSnapshot.read(from: url(roomID))
    }

    public func save(_ snapshot: ShareRoomSnapshot) throws {
        guard ShareIdentifiers.isRoomID(snapshot.roomID) else { throw ShareError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.write(to: url(snapshot.roomID))
    }

    public func remove(roomID: String) throws {
        guard ShareIdentifiers.isRoomID(roomID), FileManager.default.fileExists(atPath: url(roomID).path) else { return }
        try FileManager.default.removeItem(at: url(roomID))
    }
}

/// 방 하나의 비밀들. 키체인(이 기기에서만) 보관은 앱이 구현한다. 비밀번호 자체는 저장하지 않는다.
public struct ShareRoomSecrets: Codable, Sendable, Equatable {
    /// 뿌리 키. `ShareKeys(roomID:root:)`로 나머지를 만든다.
    public var root: Data
    public var linkSecret: Data
    public var token: String
    /// 주인 기기만.
    public var ownerKey: String?
    public var member: Int
    public var epoch: Int

    public init(root: Data, linkSecret: Data, token: String, ownerKey: String? = nil, member: Int, epoch: Int) {
        self.root = root
        self.linkSecret = linkSecret
        self.token = token
        self.ownerKey = ownerKey
        self.member = member
        self.epoch = epoch
    }
}

public protocol ShareSecretStore: Sendable {
    func secrets(roomID: String) throws -> ShareRoomSecrets?
    func save(_ secrets: ShareRoomSecrets, roomID: String) throws
    func remove(roomID: String) throws
}

// MARK: 시간

/// 다시 연결하기 전 기다리는 시간: 1, 2, 4 … 60초(지수), 여기에 0~25%를 더한다.
public enum ShareBackoff {
    public static let base: TimeInterval = 1
    public static let cap: TimeInterval = 60

    /// - Parameter jitter: 0...1.
    public static func delay(attempt: Int, jitter: Double = 0) -> TimeInterval {
        let exponent = min(max(attempt, 0), 6)
        let delay = min(cap, base * Double(1 << exponent))
        return delay * (1 + 0.25 * min(max(jitter, 0), 1))
    }
}

public enum ShareWait: Sendable, Equatable {
    case reconnect
    case lockRenewal
    case ping
}

/// 세션이 쓰는 시계와 기다림. 시험에서는 바꿔 넣는다.
public struct ShareSessionEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (ShareWait, TimeInterval) async throws -> Void
    public var jitter: @Sendable () -> Double
    public var lockRenewInterval: TimeInterval
    public var pingInterval: TimeInterval

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (ShareWait, TimeInterval) async throws -> Void = { _, seconds in try await Task.sleep(for: .seconds(seconds)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        lockRenewInterval: TimeInterval = ShareConstants.lockRenewSeconds,
        pingInterval: TimeInterval = 30
    ) {
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.lockRenewInterval = lockRenewInterval
        self.pingInterval = pingInterval
    }
}
