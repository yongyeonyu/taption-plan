import Foundation
import Synchronization

/// 벡터 지도(OpenFreeMap) 자동 오프라인 저장(MAP1108A03). Apple 지도 타일은 다루지 않는다.
/// 사용자가 실제로 본 타일만 Wi-Fi에서 저장하는 보통의 클라이언트 캐시다. 미리 받기(prefetch)는 하지 않는다.
struct OfflineVectorTileID: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}

struct OfflineVectorLimits: Sendable {
    var storeBytes = 300 * 1_024 * 1_024
    var storeFiles = 10_000
    /// 이 기간 동안 한 번도 쓰지 않은 파일은 크기와 관계없이 지운다.
    var maxUnusedAge: TimeInterval = 90 * 24 * 3_600
    var maxZoom = 14

    static let standard = Self()
}

/// OpenFreeMap 주소. TileJSON·글꼴·아이콘은 자원으로 저장한다.
enum OfflineVectorResources {
    static let host = "tiles.openfreemap.org"
    static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
}

/// 저장소 안의 위치. 타일은 판(버전)과 관계없이 z/x/y로 저장한다.
enum OfflineVectorKey: Hashable, Sendable {
    case tile(OfflineVectorTileID)
    case resource(String)

    init?(url: URL) {
        guard url.host?.lowercased() == OfflineVectorResources.host else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        // 타일: /planet/<판>/z/x/y.pbf
        if parts.count == 5, parts[0] == "planet", let z = Int(parts[2]), let x = Int(parts[3]),
           parts[4].hasSuffix(".pbf"), let y = Int(parts[4].dropLast(4)) {
            self = .tile(OfflineVectorTileID(z: z, x: x, y: y))
            return
        }
        guard let first = parts.first, ["planet", "fonts", "sprites"].contains(first) else { return nil }
        self = .resource(parts.joined(separator: "_"))
    }

    var relativePath: String {
        switch self {
        case .tile(let id): "tiles/\(id.z)/\(id.x)/\(id.y).pbf"
        case .resource(let name): "res/\(name)"
        }
    }

    /// 제공처 최대 확대(14)를 넘는 타일은 저장하지 않는다.
    func isStorable(limits: OfflineVectorLimits) -> Bool {
        if case .tile(let id) = self { return (0...limits.maxZoom).contains(id.z) }
        return true
    }

    var contentType: String {
        switch self {
        case .tile: "application/vnd.mapbox-vector-tile"
        case .resource(let name):
            if name.hasSuffix(".png") { "image/png" } else if name.hasSuffix(".pbf") { "application/x-protobuf" } else { "application/json" }
        }
    }
}

/// 파일로 된 오프라인 저장소. SQLite는 기록 전용이라 쓰지 않는다.
/// Application Support에 둔다: Caches는 저장 공간이 모자라면 iOS가 말없이 지워 본 지역이 사라진다.
/// iCloud 백업에서는 뺀다. 오래 안 쓴 파일과 크기 상한을 넘는 파일은 마지막 사용이 오래된 것부터 지운다(LRU).
final class OfflineVectorTileStore: Sendable {
    private struct Entry: Sendable {
        var bytes: Int
        var lastUsed: Date
    }

    private struct State: Sendable {
        /// 처음 필요할 때 디렉터리를 훑어 만든다. 메모리 압력이 오면 버린다.
        var index: [String: Entry]?
    }

    static let shared = OfflineVectorTileStore(root: defaultRoot)

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "OfflineVectorMap", directoryHint: .isDirectory)
    }

    /// 읽을 때마다 파일 날짜를 고치지 않도록 이 간격이 지나야 다시 적는다. 마지막 사용은 파일 수정 날짜로 남는다.
    static let touchInterval: TimeInterval = 3_600

    let root: URL
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    var isIndexLoaded: Bool { state.withLock { $0.index != nil } }

    func contains(_ key: OfflineVectorKey) -> Bool {
        state.withLock { state in
            loadIndexIfNeeded(&state)
            return state.index?[key.relativePath] != nil
        }
    }

    /// 오프라인 우선: 타일은 저장돼 있으면 늘 쓴다. 판 정보(TileJSON)·글꼴·아이콘은 네트워크가 없을 때만 쓴다.
    func shouldServe(_ url: URL, isOnline: Bool) -> Bool {
        guard let key = OfflineVectorKey(url: url) else { return false }
        if case .resource = key, isOnline { return false }
        return contains(key)
    }

    func data(for key: OfflineVectorKey) -> Data? {
        let path = key.relativePath
        let fileURL = root.appending(path: path)
        guard let data = try? Data(contentsOf: fileURL) else {
            state.withLock { $0.index?[path] = nil }
            return nil
        }
        let date = now()
        let needsTouch = state.withLock { state -> Bool in
            loadIndexIfNeeded(&state)
            let previous = state.index?[path]?.lastUsed ?? .distantPast
            state.index?[path] = Entry(bytes: data.count, lastUsed: date)
            return date.timeIntervalSince(previous) >= Self.touchInterval
        }
        if needsTouch {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }
        return data
    }

    func write(_ data: Data, for key: OfflineVectorKey) throws {
        let path = key.relativePath
        let fileURL = root.appending(path: path)
        let date = now()
        try prepareRoot()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        // 색인을 다시 읽어도 같은 마지막 사용이 나오게 파일 날짜를 맞춘다.
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        state.withLock { state in
            loadIndexIfNeeded(&state)
            state.index?[path] = Entry(bytes: data.count, lastUsed: date)
        }
    }

    /// 사용하지 않은 지 `maxUnusedAge`가 지난 파일을 지우고, 그래도 상한을 넘으면 마지막 사용이 오래된 파일부터 지운다.
    /// 메인 스레드에서 부르지 않는다. 지운 개수를 돌려준다.
    @discardableResult
    func evict(limits: OfflineVectorLimits) -> Int {
        let cutoff = now().addingTimeInterval(-limits.maxUnusedAge)
        let victims = state.withLock { state -> [String] in
            loadIndexIfNeeded(&state)
            guard var index = state.index else { return [] }
            var bytes = index.values.reduce(0) { $0 + $1.bytes }
            var removed: [String] = []
            for (path, entry) in index.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                guard entry.lastUsed < cutoff || bytes > limits.storeBytes || index.count > limits.storeFiles else { break }
                index[path] = nil
                bytes -= entry.bytes
                removed.append(path)
            }
            state.index = index
            return removed
        }
        for path in victims {
            try? FileManager.default.removeItem(at: root.appending(path: path))
        }
        return victims.count
    }

    /// 메모리 경고 때 색인만 버린다. 파일은 그대로이고 다음 조회에서 다시 읽는다.
    func purgeMemory() {
        state.withLock { $0.index = nil }
    }

    private func prepareRoot() throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
    }

    private func loadIndexIfNeeded(_ state: inout State) {
        guard state.index == nil else { return }
        var index: [String: Entry] = [:]
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let path = enumerator.nextObject() as? String {
                guard let attributes = enumerator.fileAttributes,
                      attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let date = attributes[.modificationDate] as? Date ?? .distantPast
                index[path] = Entry(bytes: bytes, lastUsed: date)
            }
        }
        state.index = index
    }
}
