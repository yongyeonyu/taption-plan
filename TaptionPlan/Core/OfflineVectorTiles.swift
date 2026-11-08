import Foundation
import Synchronization

/// 벡터 지도(OpenFreeMap) 오프라인 저장(MAP1108A02). Apple 지도 타일은 다루지 않는다.
/// OpenFreeMap 약관: 한 번에 3,000타일 또는 50MB 이하, 병렬 4개 이하, 앱을 밝히는 User-Agent.
struct OfflineVectorTileID: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}

struct OfflineVectorLimits: Sendable {
    var perDownloadTiles = 3_000
    var perDownloadBytes = 50 * 1_024 * 1_024
    var storeBytes = 300 * 1_024 * 1_024
    var storeFiles = 10_000
    /// 약관 상한은 4개. 여유를 두고 2개만 쓴다.
    var maxParallel = 2
    var maxZoom = 14

    static let standard = Self()
}

/// 남·서·북·동 경계(도). 경도는 날짜 변경선을 넘지 않게 자른다.
struct OfflineVectorBounds: Equatable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    init(south: Double, west: Double, north: Double, east: Double) {
        let limit = OfflineVectorTileMath.maxLatitude
        self.south = min(max(min(south, north), -limit), limit)
        self.north = min(max(max(south, north), -limit), limit)
        self.west = min(max(min(west, east), -180), 180)
        self.east = min(max(max(west, east), -180), 180)
    }

    init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.init(
            south: centerLatitude - latitudeDelta / 2,
            west: centerLongitude - longitudeDelta / 2,
            north: centerLatitude + latitudeDelta / 2,
            east: centerLongitude + longitudeDelta / 2
        )
    }
}

enum OfflineVectorTileMath {
    static let maxLatitude = 85.05112878

    static func tileX(longitude: Double, zoom: Int) -> Int {
        let n = 1 << zoom
        let x = Int(floor((longitude + 180) / 360 * Double(n)))
        return min(max(x, 0), n - 1)
    }

    static func tileY(latitude: Double, zoom: Int) -> Int {
        let n = 1 << zoom
        let radians = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        let y = Int(floor((1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * Double(n)))
        return min(max(y, 0), n - 1)
    }

    static func ranges(_ bounds: OfflineVectorBounds, zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let x = tileX(longitude: bounds.west, zoom: zoom)...tileX(longitude: bounds.east, zoom: zoom)
        // 북쪽이 y가 작다.
        let y = tileY(latitude: bounds.north, zoom: zoom)...tileY(latitude: bounds.south, zoom: zoom)
        return (x, y)
    }

    static func tileCount(_ bounds: OfflineVectorBounds, zooms: ClosedRange<Int>) -> Int {
        zooms.reduce(0) { total, zoom in
            let r = ranges(bounds, zoom: zoom)
            return total + r.x.count * r.y.count
        }
    }

    static func tileIDs(_ bounds: OfflineVectorBounds, zooms: ClosedRange<Int>) -> [OfflineVectorTileID] {
        zooms.flatMap { zoom in
            let r = ranges(bounds, zoom: zoom)
            return r.y.flatMap { y in r.x.map { OfflineVectorTileID(z: zoom, x: $0, y: y) } }
        }
    }

    /// 서울 도심 타일을 재 본 값(2026-11-08, 75~200KB)에 맞춘 넉넉한 추정. 실제 바이트 상한은 받으면서 따로 지킨다.
    static func estimatedBytes(zoom: Int) -> Int {
        switch zoom {
        case ..<6: 80 * 1_024
        case 6...11: 150 * 1_024
        case 12: 120 * 1_024
        case 13: 90 * 1_024
        default: 160 * 1_024
        }
    }
}

/// 내려받기 전에 보여 줄 범위·추정 크기와 상한 위반.
struct OfflineVectorDownloadPlan: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        case tooManyTiles
        case tooLarge
    }

    let bounds: OfflineVectorBounds
    let zooms: ClosedRange<Int>
    let tileCount: Int
    let estimatedBytes: Int
    let problem: Problem?

    var requestCount: Int { tileCount + OfflineVectorResources.urls.count }

    init(bounds: OfflineVectorBounds, zooms: ClosedRange<Int>, limits: OfflineVectorLimits = .standard) {
        let lower = min(max(zooms.lowerBound, 0), limits.maxZoom)
        let upper = min(max(zooms.upperBound, lower), limits.maxZoom)
        self.bounds = bounds
        self.zooms = lower...upper
        tileCount = OfflineVectorTileMath.tileCount(bounds, zooms: self.zooms)
        estimatedBytes = self.zooms.reduce(0) { total, zoom in
            let r = OfflineVectorTileMath.ranges(bounds, zoom: zoom)
            return total + r.x.count * r.y.count * OfflineVectorTileMath.estimatedBytes(zoom: zoom)
        }
        if tileCount + OfflineVectorResources.urls.count > limits.perDownloadTiles {
            problem = .tooManyTiles
        } else if estimatedBytes > limits.perDownloadBytes {
            problem = .tooLarge
        } else {
            problem = nil
        }
    }
}

/// 타일 외에 오프라인 표시에 필요한 자원. 한글·한자·가나는 MapLibre가 기기 글꼴로 그려 글리프를 받지 않는다.
enum OfflineVectorResources {
    static let host = "tiles.openfreemap.org"
    static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!

    static let urls: [URL] = {
        let sprites = ["ofm.json", "ofm.png", "ofm@2x.json", "ofm@2x.png"].map {
            "https://tiles.openfreemap.org/sprites/ofm_f384/\($0)"
        }
        let glyphs = ["Noto%20Sans%20Regular", "Noto%20Sans%20Bold"].flatMap { font in
            ["0-255", "256-511", "8192-8447"].map { "https://tiles.openfreemap.org/fonts/\(font)/\($0).pbf" }
        }
        return [tileJSONURL] + (sprites + glyphs).compactMap(URL.init(string:))
    }()
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

    var contentType: String {
        switch self {
        case .tile: "application/vnd.mapbox-vector-tile"
        case .resource(let name):
            if name.hasSuffix(".png") { "image/png" } else if name.hasSuffix(".pbf") { "application/x-protobuf" } else { "application/json" }
        }
    }
}

/// 파일로 된 오프라인 저장소. SQLite는 기록 전용이라 쓰지 않는다.
/// Application Support에 둔다: Caches는 저장 공간이 모자라면 iOS가 말없이 지워 오프라인 영역이 사라진다.
/// iCloud 백업에서는 뺀다. 크기 상한을 넘으면 오래 안 쓴 파일부터 지운다(LRU).
final class OfflineVectorTileStore: Sendable {
    struct Summary: Equatable, Sendable {
        var bytes = 0
        var tiles = 0
    }

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

    /// 읽을 때마다 파일 날짜를 고치지 않도록 이 간격이 지나야 다시 적는다.
    static let touchInterval: TimeInterval = 3_600

    let root: URL
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

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
        try prepareRoot()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        let entry = Entry(bytes: data.count, lastUsed: now())
        state.withLock { state in
            loadIndexIfNeeded(&state)
            state.index?[path] = entry
        }
    }

    func summary() -> Summary {
        state.withLock { state in
            loadIndexIfNeeded(&state)
            return (state.index ?? [:]).reduce(into: Summary()) { result, item in
                result.bytes += item.value.bytes
                if item.key.hasPrefix("tiles/") { result.tiles += 1 }
            }
        }
    }

    /// 상한을 넘으면 마지막 사용이 오래된 파일부터 지운다. 지운 개수를 돌려준다.
    @discardableResult
    func enforceLimit(maxBytes: Int, maxFiles: Int) -> Int {
        let victims = state.withLock { state -> [String] in
            loadIndexIfNeeded(&state)
            guard var index = state.index else { return [] }
            var bytes = index.values.reduce(0) { $0 + $1.bytes }
            var removed: [String] = []
            for (path, entry) in index.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                guard bytes > maxBytes || index.count > maxFiles else { break }
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

    func removeAll() {
        state.withLock { state in
            try? FileManager.default.removeItem(at: root)
            state.index = [:]
        }
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
