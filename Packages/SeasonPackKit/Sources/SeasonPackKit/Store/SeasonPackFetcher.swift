import Foundation
import Synchronization

public struct SeasonPackReply: Sendable {
    public var status: Int
    public var data: Data
    public var etag: String?
    public var serverDate: Date?
    public init(status: Int, data: Data, etag: String? = nil, serverDate: Date? = nil) {
        self.status = status; self.data = data; self.etag = etag; self.serverDate = serverDate
    }
}

/// 중계 서버의 `/public/assets/<키>` 읽기 하나. 키는 `packs/season/…`이다.
public protocol SeasonPackTransport: Sendable {
    func get(key: String, etag: String?) async -> SeasonPackReply?
}

/// 인증·식별자·쿼리 없는 `GET` 하나, 8초 제한, 쿠키 없음. 좌표·기기 id·계정을 싣지 않는다.
public struct SeasonPackURLSessionTransport: SeasonPackTransport {
    private let urlForKey: @Sendable (String) -> URL?

    public init(urlForKey: @escaping @Sendable (String) -> URL?) { self.urlForKey = urlForKey }

    public static func isValidKey(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= 8 && key.count <= 200 && parts.allSatisfy { SeasonPackValidation.isKeyName(String($0)) }
    }

    public func request(key: String, etag: String?) -> URLRequest? {
        guard Self.isValidKey(key), let url = urlForKey(key) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    public func get(key: String, etag: String?) async -> SeasonPackReply? {
        guard let request = request(key: key, etag: etag) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        guard let (data, response) = try? await URLSession(configuration: configuration).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let date = http.value(forHTTPHeaderField: "Date").flatMap(Self.parseHTTPDate)
        return SeasonPackReply(status: http.statusCode, data: data, etag: http.value(forHTTPHeaderField: "ETag"), serverDate: date)
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

public struct SeasonPackRefreshResult: Sendable, Equatable {
    /// 이번에 새로 설치한 팩(id, version). 첫 수신 시연의 신호다.
    public var installed: [SeasonPackRef] = []
    public var skippedReason: String?
}

public struct SeasonPackRef: Sendable, Equatable, Hashable {
    public var id: String
    public var version: Int
    public init(id: String, version: Int) { self.id = id; self.version = version }
}

/// 받기 정책: 30분 쿨다운·ETag·8초·한 번 시도·실패는 조용히(공지 `AnnouncementService`와 같다).
/// 인덱스 → 지금과 ±45일 안의 팩 매니페스트 → 파일(팩당 ≤40) → 검증 → 설치.
public final class SeasonPackFetcher: Sendable {
    public static let cooldown: TimeInterval = 30 * 60
    public static let nearDays: TimeInterval = 45 * 86400
    static let indexKey = "packs/season/index.json"
    static let etagKey = "seasonPack.index.etag"
    static let indexCacheKey = "seasonPack.index.cache"
    static let attemptKey = "seasonPack.fetch.lastAttempt"

    private let store: SeasonPackStore
    private let transport: SeasonPackTransport
    private let defaults: SeasonPackDefaults
    private let appBuild: @Sendable () -> Int?
    private let now: @Sendable () -> Date
    private let windows: @Sendable () -> SeasonPackWindows
    private let allowsLargeDownload: @Sendable () -> Bool
    private let knownVersion: @Sendable (String) -> Int
    private let onServerDate: @Sendable (Date) -> Void
    private let running = Mutex(false)

    public init(
        store: SeasonPackStore,
        transport: SeasonPackTransport,
        defaults: SeasonPackDefaults = SeasonPackDefaults(),
        appBuild: @escaping @Sendable () -> Int? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        windows: @escaping @Sendable () -> SeasonPackWindows = { SeasonPackWindows() },
        allowsLargeDownload: @escaping @Sendable () -> Bool = { true },
        knownVersion: @escaping @Sendable (String) -> Int = { _ in 0 },
        onServerDate: @escaping @Sendable (Date) -> Void = { _ in }
    ) {
        self.store = store; self.transport = transport; self.defaults = defaults; self.appBuild = appBuild; self.now = now
        self.windows = windows; self.allowsLargeDownload = allowsLargeDownload; self.knownVersion = knownVersion; self.onServerDate = onServerDate
    }

    public func refresh() async -> SeasonPackRefreshResult {
        guard running.withLock({ state in if state { return false }; state = true; return true }) else {
            return SeasonPackRefreshResult(skippedReason: "running")
        }
        defer { running.withLock { $0 = false } }
        let current = now().timeIntervalSince1970
        if let last = defaults.double(Self.attemptKey), current >= last, current - last < Self.cooldown {
            return SeasonPackRefreshResult(skippedReason: "cooldown")
        }
        defaults.set(current, Self.attemptKey)

        guard let reply = await transport.get(key: Self.indexKey, etag: defaults.string(Self.etagKey)) else {
            return SeasonPackRefreshResult(skippedReason: "offline")
        }
        if let date = reply.serverDate { onServerDate(date) }
        let indexData: Data
        switch reply.status {
        case 200:
            indexData = reply.data
            if let etag = reply.etag, !etag.isEmpty { defaults.set(etag, Self.etagKey) } else { defaults.remove(Self.etagKey) }
            defaults.setData(reply.data, Self.indexCacheKey)
        case 304:
            guard let cached = defaults.data(Self.indexCacheKey) else { return SeasonPackRefreshResult(skippedReason: "not-modified") }
            indexData = cached
        default:
            return SeasonPackRefreshResult(skippedReason: "status \(reply.status)")
        }
        guard let index = SeasonPackIndex.decode(indexData) else { return SeasonPackRefreshResult(skippedReason: "bad-index") }

        var result = SeasonPackRefreshResult()
        for entry in index.packs {
            if let ref = await install(entry) { result.installed.append(ref) }
        }
        return result
    }

    private func install(_ entry: SeasonPackIndex.Entry) async -> SeasonPackRef? {
        guard SeasonPackValidation.isKeyName(entry.id), !SeasonPackValidation.reservedIDs.contains(entry.id), entry.version >= 1,
              entry.manifest == "packs/season/\(entry.id)/\(entry.version)/manifest.json" else { return nil }
        if let required = entry.requiresAppBuild, let build = appBuild(), required > build { return nil }
        if entry.version <= knownVersion(entry.id) || store.hasInstalled(id: entry.id, version: entry.version) { return nil }

        guard let manifestReply = await transport.get(key: entry.manifest, etag: nil), manifestReply.status == 200 else { return nil }
        if let date = manifestReply.serverDate { onServerDate(date) }
        guard let manifest = try? JSONDecoder().decode(SeasonPackManifest.self, from: manifestReply.data),
              manifest.id == entry.id, manifest.version == entry.version, Self.isNear(manifest, now: now(), windows: windows()) else { return nil }
        let total = manifest.assets.reduce(0) { $0 + $1.bytes }
        if total > SeasonPackLimits.cellularBytes && !allowsLargeDownload() { return nil }
        guard manifest.assets.count <= SeasonPackLimits.filesPerPack else { return nil }

        var files: [String: Data] = [:]
        var serverDate: Date?
        for asset in manifest.assets {
            guard SeasonPackValidation.isRelativePath(asset.path),
                  let reply = await transport.get(key: "packs/season/\(entry.id)/\(entry.version)/\(asset.path)", etag: nil),
                  reply.status == 200 else { return nil }
            files[asset.path] = reply.data
            serverDate = reply.serverDate ?? serverDate
        }
        if let serverDate { onServerDate(serverDate) }
        guard (try? store.install(manifestData: manifestReply.data, files: files, appBuild: appBuild(), serverDate: serverDate, now: now())) != nil else { return nil }
        return SeasonPackRef(id: entry.id, version: entry.version)
    }

    /// 창이 지금 ±45일과 겹치는가(지난 창·먼 창의 큰 파일은 받지 않는다).
    static func isNear(_ manifest: SeasonPackManifest, now: Date, windows: SeasonPackWindows) -> Bool {
        let around = DateInterval(start: now.addingTimeInterval(-nearDays), end: now.addingTimeInterval(nearDays))
        let year = windows.calendar.component(.year, from: now)
        return manifest.event.windows.contains { window in
            [year - 1, year, year + 1].contains { windows.interval(of: window, startYear: $0)?.intersects(around) == true }
        }
    }
}

/// `UserDefaults` 얇은 손잡이(스위트 이름만 들고 있어 `Sendable`이다).
public struct SeasonPackDefaults: Sendable {
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var store: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }
    func double(_ key: String) -> Double? { store.object(forKey: key) as? Double }
    func string(_ key: String) -> String? { store.string(forKey: key) }
    func data(_ key: String) -> Data? { store.data(forKey: key) }
    func bool(_ key: String) -> Bool { store.bool(forKey: key) }
    func set(_ value: Double, _ key: String) { store.set(value, forKey: key) }
    func set(_ value: String, _ key: String) { store.set(value, forKey: key) }
    func set(_ value: Bool, _ key: String) { store.set(value, forKey: key) }
    func setData(_ value: Data, _ key: String) { store.set(value, forKey: key) }
    func remove(_ key: String) { store.removeObject(forKey: key) }
    func removeAll(withPrefix prefix: String) {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix(prefix) { store.removeObject(forKey: key) }
    }
}
