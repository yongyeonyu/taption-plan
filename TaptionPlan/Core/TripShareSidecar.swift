import Foundation
import Synchronization
import TaptionTripShare

/// 로컬 여행 하나와 방 하나의 연결(TSH1114A26). 곁 파일에만 있고 SQLite·백업에는 들어가지 않는다.
struct TripShareLink: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case owner, member }

    enum Phase: String, Codable, Sendable {
        /// 주인이 방을 만들고 기존 일정을 올리는 중. 이 동안은 「방이 이긴다」 맞춤을 돌리지 않는다.
        case uploading
        case sharing
        /// 내보내졌거나 나갔거나 방이 사라졌다. 로컬 사본은 보통 여행으로 남는다.
        case ended
    }

    var roomID: String
    var tripID: String
    var role: Role
    var phase: Phase
    /// 올리는 중에 이미 올린 방 항목 id(끊기면 여기서 이어 올린다).
    var uploaded: [String] = []
    var joinedAt = Date()

    var id: String { roomID }
}

/// 곁 파일(TSH1114A26): `Application Support/TripShare/<roomId>.json` 하나에 연결 정보와 방의 로컬 사본을 함께 둔다.
/// 방이 살아 있으면 처음부터 다시 받을 수 있는 캐시라 기기 백업에서 뺀다. **키·토큰은 넣지 않는다**(키체인).
struct TripShareSidecar: ShareSnapshotStore {
    /// 칸마다 따로 푼다: 한 칸(방 사본 등)이 깨져도 연결은 남는다(TSA1117A01). 없는 칸은 예전 파일이다.
    private struct File: Codable {
        var format = 1
        var link: TripShareLink?
        var room: ShareRoomSnapshot?
        /// 방에서 본 사람들의 이름(참여자 번호 → 닉네임). 나간 사람의 카드는 서버가 지우므로 여기서 읽는다.
        var names: [Int: String]?

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(Int.self, forKey: .format)
            link = try? container.decodeIfPresent(TripShareLink.self, forKey: .link)
            room = try? container.decodeIfPresent(ShareRoomSnapshot.self, forKey: .room)
            names = try? container.decodeIfPresent([Int: String].self, forKey: .names)
        }
    }

    /// 읽고 고쳐 쓰는 사이에 다른 쓰기가 끼지 않게 한다.
    private static let gate = Mutex(())

    let directory: URL

    static var live: TripShareSidecar {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return TripShareSidecar(directory: base.appendingPathComponent("TripShare", isDirectory: true))
    }

    private func url(_ roomID: String) -> URL { directory.appendingPathComponent(roomID + ".json") }

    private func read(_ roomID: String) -> File? {
        guard ShareIdentifiers.isRoomID(roomID), let data = try? Data(contentsOf: url(roomID)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1 else { return nil }
        return file
    }

    /// - Parameter linked: 참이면 연결이 적힌 파일에만 쓴다(잊은 방의 파일을 늦은 쓰기가 되살리지 않게).
    private func change(_ roomID: String, linked: Bool = false, _ edit: (inout File) -> Void) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { throw ShareError.invalidResponse }
        try Self.gate.withLock { _ in
            var file = read(roomID) ?? File()
            guard !linked || file.link != nil else { return }
            var folder = directory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            edit(&file)
            try JSONEncoder().encode(file).write(to: url(roomID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: 연결

    /// 이 기기가 아는 방들(합류한 순).
    func links() -> [TripShareLink] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { read($0.deletingPathExtension().lastPathComponent)?.link }
            .sorted { ($0.joinedAt, $0.roomID) < ($1.joinedAt, $1.roomID) }
    }

    func link(roomID: String) -> TripShareLink? { read(roomID)?.link }

    func save(_ link: TripShareLink) throws {
        try change(link.roomID) { $0.link = link }
    }

    // MARK: 방의 로컬 사본(`ShareSnapshotStore`)

    func snapshot(roomID: String) -> ShareRoomSnapshot? { read(roomID)?.room }

    /// 연결이 없는 방(잊었거나 아직 적지 않은 방)이면 쓰지 않는다.
    func save(_ snapshot: ShareRoomSnapshot) throws {
        try change(snapshot.roomID, linked: true) { $0.room = snapshot }
    }

    // MARK: 지난 이름(TSA1117A01)

    func formerNames(roomID: String) -> [Int: String] { read(roomID)?.names ?? [:] }

    func saveFormerNames(_ names: [Int: String], roomID: String) throws {
        try change(roomID, linked: true) { $0.names = names.isEmpty ? nil : names }
    }

    /// 연결과 사본을 함께 지운다. 로컬 여행(SQLite)은 건드리지 않는다.
    func remove(roomID: String) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { return }
        try Self.gate.withLock { _ in
            try? FileManager.default.removeItem(at: expensesURL(roomID))
            guard FileManager.default.fileExists(atPath: url(roomID).path) else { return }
            try FileManager.default.removeItem(at: url(roomID))
        }
    }

    // MARK: 가계부에 넣은 방 지출(TSF1115A01)

    /// 작은 파일을 따로 둔다: 방 사본과 함께 두면 지출 하나에 사본 전체를 다시 쓰게 된다.
    private func expensesURL(_ roomID: String) -> URL { directory.appendingPathComponent(roomID + ".expenses") }

    /// 방에서 가계부로 투영해 넣은 지출의 방 항목 id. 가계부 기록에는 「방에서 왔다」는 표지가 없어 여기에 둔다.
    func projectedExpenses(roomID: String) -> Set<String> {
        guard ShareIdentifiers.isRoomID(roomID), let data = try? Data(contentsOf: expensesURL(roomID)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// 연결을 지운 방이면 쓰지 않는다(늦게 온 투영이 파일을 되살리지 않게).
    func saveProjectedExpenses(_ ids: Set<String>, roomID: String) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { throw ShareError.invalidResponse }
        try Self.gate.withLock { _ in
            guard FileManager.default.fileExists(atPath: url(roomID).path) else { return }
            try JSONEncoder().encode(ids.sorted()).write(to: expensesURL(roomID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
