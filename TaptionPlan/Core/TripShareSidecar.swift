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
    private struct File: Codable {
        var format = 1
        var link: TripShareLink?
        var room: ShareRoomSnapshot?
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

    private func change(_ roomID: String, _ edit: (inout File) -> Void) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { throw ShareError.invalidResponse }
        try Self.gate.withLock { _ in
            var folder = directory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            var file = read(roomID) ?? File()
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

    func save(_ snapshot: ShareRoomSnapshot) throws {
        try change(snapshot.roomID) { $0.room = snapshot }
    }

    /// 연결과 사본을 함께 지운다. 로컬 여행(SQLite)은 건드리지 않는다.
    func remove(roomID: String) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { return }
        try Self.gate.withLock { _ in
            guard FileManager.default.fileExists(atPath: url(roomID).path) else { return }
            try FileManager.default.removeItem(at: url(roomID))
        }
    }
}
