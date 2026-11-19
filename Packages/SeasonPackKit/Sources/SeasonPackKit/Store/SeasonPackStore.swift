import Foundation
import Synchronization

/// 검증을 마친 팩 한 벌. 그림·소리는 `directory`에서 필요할 때 읽는다.
public struct SeasonPack: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case seed, installed }

    public var manifest: SeasonPackManifest
    public var directory: URL
    public var source: Source

    public var id: String { manifest.id }
    public var version: Int { manifest.version }

    public func assetURL(_ assetID: String) -> URL? {
        manifest.assets.first { $0.id == assetID }.map { directory.appendingPathComponent($0.path) }
    }

    public func assetData(_ assetID: String) -> Data? {
        assetURL(assetID).flatMap { try? Data(contentsOf: $0) }
    }
}

/// 폴더에서 팩을 읽고 검증한다(시드·설치본 공통 — 예외 경로를 만들지 않는다).
public enum SeasonPackLoader {
    public static let manifestName = "manifest.json"

    public static func load(directory: URL, source: SeasonPack.Source, appBuild: Int?) -> SeasonPack? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(SeasonPackManifest.self, from: data) else { return nil }
        var files: [String: Data] = [:]
        for asset in manifest.assets {
            guard SeasonPackValidation.isRelativePath(asset.path),
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent(asset.path)) else { return nil }
            files[asset.path] = bytes
        }
        guard SeasonPackValidation.validate(manifest, files: files, appBuild: appBuild).isValid else { return nil }
        return SeasonPack(manifest: manifest, directory: directory, source: source)
    }
}

public struct SeasonPackInstallRecord: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var manifestSha256: String
    public var installedAt: Date
    public var serverDate: Date?
    public var lastUsedAt: Date
}

public enum SeasonPackStoreError: Error, Sendable, Equatable {
    case invalid(String)
    case io
}

/// `Application Support/SeasonPacks/<packId>/<version>/` 아래에 받은 팩을 둔다. 디렉터리는 주입받는다(시험은 임시 폴더).
/// 쓰기는 임시 폴더 → 검증 → 이름 바꾸기라 중간에 끊겨도 반쯤 쓴 팩이 남지 않는다. 지난해 팩은 다음 해에 다시 쓰므로 지우지 않고,
/// 상한(최근 3개 버전·32MB)을 넘을 때만 가장 오래 안 쓴 것부터 지운다. 백업에서는 뺀다.
public final class SeasonPackStore: Sendable {
    public static let recordName = "installed.json"
    public static let memosFolder = "memos"

    public let root: URL
    private let lock = Mutex(())

    public init(root: URL) { self.root = root }

    /// 매니페스트 바이트와 파일을 검증해 설치한다. 같은 id·버전이 이미 있으면 바꾼다.
    @discardableResult
    public func install(manifestData: Data, files: [String: Data], appBuild: Int?, serverDate: Date? = nil, now: Date = Date()) throws -> SeasonPack {
        guard let manifest = try? JSONDecoder().decode(SeasonPackManifest.self, from: manifestData) else { throw SeasonPackStoreError.invalid("manifest") }
        let result = SeasonPackValidation.validate(manifest, files: files, appBuild: appBuild)
        guard result.isValid else { throw SeasonPackStoreError.invalid("\(result)") }
        return try lock.withLock { _ in
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            Self.excludeFromBackup(root)
            let temp = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: temp) }
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            for (path, data) in files {
                let url = temp.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try manifestData.write(to: temp.appendingPathComponent(SeasonPackLoader.manifestName))
            let record = SeasonPackInstallRecord(
                id: manifest.id, version: manifest.version, manifestSha256: SeasonPackValidation.sha256Hex(manifestData),
                installedAt: now, serverDate: serverDate, lastUsedAt: now
            )
            try JSONEncoder().encode(record).write(to: temp.appendingPathComponent(Self.recordName))
            guard SeasonPackLoader.load(directory: temp, source: .installed, appBuild: appBuild) != nil else { throw SeasonPackStoreError.invalid("reload") }

            let packFolder = root.appendingPathComponent(manifest.id, isDirectory: true)
            try fm.createDirectory(at: packFolder, withIntermediateDirectories: true)
            Self.excludeFromBackup(packFolder)
            let destination = packFolder.appendingPathComponent(String(manifest.version), isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
            Self.excludeFromBackup(destination)
            return SeasonPack(manifest: manifest, directory: destination, source: .installed)
        }
    }

    /// 설치본 한 버전을 지운다(롤백: 새 버전이 말썽이면 지우고 이전 버전이 다시 쓰이게 한다).
    @discardableResult
    public func discard(id: String, version: Int) -> Bool {
        guard SeasonPackValidation.isKeyName(id), version >= 1 else { return false }
        return lock.withLock { _ in
            let folder = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(String(version), isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return false }
            return (try? FileManager.default.removeItem(at: folder)) != nil
        }
    }

    /// 디스크의 팩을 모두 다시 읽어 검증한다. 손상된 것은 건너뛴다(그 팩만 버리고 기본 모습으로).
    public func installedPacks(appBuild: Int?) -> [SeasonPack] {
        lock.withLock { _ in
            versionFolders().compactMap { SeasonPackLoader.load(directory: $0, source: .installed, appBuild: appBuild) }
        }
    }

    public func record(id: String, version: Int) -> SeasonPackInstallRecord? {
        let url = root.appendingPathComponent(id).appendingPathComponent(String(version)).appendingPathComponent(Self.recordName)
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SeasonPackInstallRecord.self, from: $0) }
    }

    public func hasInstalled(id: String, version: Int) -> Bool { record(id: id, version: version) != nil }

    /// 쓰고 있는 팩의 시각을 갱신한다(상한을 넘을 때 오래 안 쓴 것부터 지운다).
    public func touch(id: String, version: Int, now: Date = Date()) {
        lock.withLock { _ in
            guard var record = record(id: id, version: version) else { return }
            record.lastUsedAt = now
            let url = root.appendingPathComponent(id).appendingPathComponent(String(version)).appendingPathComponent(Self.recordName)
            try? JSONEncoder().encode(record).write(to: url)
        }
    }

    /// 한 id당 최근 3개 버전, 전체 32MB. 넘으면 가장 오래 안 쓴 것부터 지우되 `protecting`(지금 쓰는 팩 id)은 지우지 않는다.
    public func enforceLimits(protecting: Set<String>, maxVersions: Int = SeasonPackLimits.storedVersions, maxBytes: Int = SeasonPackLimits.storedBytes) {
        lock.withLock { _ in
            let fm = FileManager.default
            struct Entry { var url: URL; var id: String; var version: Int; var used: Date; var bytes: Int }
            func entries() -> [Entry] {
                versionFolders().compactMap { url in
                    guard let version = Int(url.lastPathComponent) else { return nil }
                    let id = url.deletingLastPathComponent().lastPathComponent
                    let used = record(id: id, version: version)?.lastUsedAt ?? .distantPast
                    return Entry(url: url, id: id, version: version, used: used, bytes: Self.size(of: url))
                }
            }
            for (id, group) in Dictionary(grouping: entries(), by: \.id) where group.count > maxVersions && !protecting.contains(id) {
                for old in group.sorted(by: { $0.version > $1.version }).dropFirst(maxVersions) { try? fm.removeItem(at: old.url) }
            }
            var all = entries()
            var total = all.reduce(0) { $0 + $1.bytes }
            for victim in all.sorted(by: { $0.used < $1.used }) where total > maxBytes && !protecting.contains(victim.id) {
                try? fm.removeItem(at: victim.url)
                total -= victim.bytes
                all.removeAll { $0.url == victim.url }
            }
        }
    }

    /// 「모든 데이터 삭제」: 팩과 메모를 모두 지운다.
    public func removeAll() {
        lock.withLock { _ in try? FileManager.default.removeItem(at: root) }
    }

    public func totalBytes() -> Int { Self.size(of: root) }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func versionFolders() -> [URL] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return ids.filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != Self.memosFolder }.flatMap { idFolder in
            ((try? fm.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? []).filter { Int($0.lastPathComponent) != nil }
        }
    }

    private static func size(of url: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
