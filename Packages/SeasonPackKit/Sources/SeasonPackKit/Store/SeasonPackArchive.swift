import Foundation

public enum SeasonPackArchiveError: Error, Equatable, Sendable {
    case badMagic, unsupportedVersion, truncated, trailingBytes, tooLarge
    case badManifest, tooManyFiles, badPath(String), duplicatePath(String), sizeMismatch(String)
}

/// 팩 하나를 파일 하나로 묶은 `.bpack`. 압축하지 않는 단순 컨테이너라 풀 때 부풀 일이 없고(선언한 크기 = 실제 크기),
/// 파일 경로는 매니페스트의 `assets`에서만 오며 `SeasonPackValidation.isRelativePath`로 걸러 경로 탈출이 없다.
///
///     "BSPK" | u8 형식 버전(1) | u32 빅엔디언 매니페스트 길이 | 매니페스트 JSON | 매니페스트 `assets` 순서대로 파일 바이트(각 `bytes`)
///
/// 개별 파일 무결성은 매니페스트의 SHA-256이, 파일 전체 무결성은 카탈로그의 SHA-256이 지킨다.
public enum SeasonPackArchive {
    public static let magic = Data("BSPK".utf8)
    public static let formatVersion: UInt8 = 1
    public static let maxManifestBytes = 256 * 1024
    static let headerBytes = 4 + 1 + 4

    public static func encode(manifestData: Data, files: [String: Data]) throws -> Data {
        guard manifestData.count <= maxManifestBytes, let manifest = try? JSONDecoder().decode(SeasonPackManifest.self, from: manifestData) else {
            throw SeasonPackArchiveError.badManifest
        }
        var out = magic
        out.append(formatVersion)
        withUnsafeBytes(of: UInt32(manifestData.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(manifestData)
        for asset in manifest.assets {
            guard let data = files[asset.path], data.count == asset.bytes else { throw SeasonPackArchiveError.sizeMismatch(asset.path) }
            out.append(data)
        }
        return out
    }

    /// 선언한 크기·개수·경로를 먼저 모두 확인한 뒤에야 파일 바이트를 읽는다. 어긋나면 아무것도 돌려주지 않는다.
    public static func decode(from url: URL) throws -> (manifestData: Data, files: [String: Data]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Int((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: 0)
        guard total >= headerBytes, let header = try handle.read(upToCount: headerBytes), header.count == headerBytes else { throw SeasonPackArchiveError.truncated }
        guard header.prefix(4) == magic else { throw SeasonPackArchiveError.badMagic }
        guard header[header.startIndex + 4] == formatVersion else { throw SeasonPackArchiveError.unsupportedVersion }
        let length = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maxManifestBytes, headerBytes + length <= total else { throw SeasonPackArchiveError.badManifest }
        guard let manifestData = try handle.read(upToCount: length), manifestData.count == length,
              let manifest = try? JSONDecoder().decode(SeasonPackManifest.self, from: manifestData) else { throw SeasonPackArchiveError.badManifest }
        guard manifest.assets.count <= SeasonPackLimits.filesPerPack else { throw SeasonPackArchiveError.tooManyFiles }
        var seen = Set<String>(), sum = 0
        for asset in manifest.assets {
            guard SeasonPackValidation.isRelativePath(asset.path) else { throw SeasonPackArchiveError.badPath(asset.path) }
            guard seen.insert(asset.path).inserted else { throw SeasonPackArchiveError.duplicatePath(asset.path) }
            guard asset.bytes >= 0, asset.bytes <= SeasonPackLimits.packBytes else { throw SeasonPackArchiveError.tooLarge }
            sum += asset.bytes
            guard sum <= SeasonPackLimits.packBytes else { throw SeasonPackArchiveError.tooLarge }
        }
        let expected = headerBytes + length + sum
        guard total >= expected else { throw SeasonPackArchiveError.truncated }
        guard total == expected else { throw SeasonPackArchiveError.trailingBytes }
        var files: [String: Data] = [:]
        for asset in manifest.assets {
            guard let data = try handle.read(upToCount: asset.bytes), data.count == asset.bytes else { throw SeasonPackArchiveError.truncated }
            files[asset.path] = data
        }
        return (manifestData, files)
    }
}
