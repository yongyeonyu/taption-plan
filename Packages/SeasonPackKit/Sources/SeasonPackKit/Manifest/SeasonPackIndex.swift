import Foundation

/// `packs/season/index.json` — 배급 목록. 작아서 앱이 먼저 읽는다.
public struct SeasonPackIndex: Codable, Sendable, Equatable {
    public static let format = "bokki-season-packs"

    /// 팩 하나를 묶은 `.bpack` 파일(HTTP Range·ETag를 지원하는 곳에 둔다). 크기와 SHA-256으로 받은 파일 전체를 검증한다.
    public struct Archive: Codable, Sendable, Equatable {
        public var key: String
        public var bytes: Int
        public var sha256: String
        public init(key: String, bytes: Int, sha256: String) { self.key = key; self.bytes = bytes; self.sha256 = sha256 }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var version: Int
        /// 파일 하나로 받는 새 방식. 없으면 `manifest`로 파일을 하나씩 받는 예전 방식이다.
        public var archive: Archive?
        public var manifest: String?
        public var requiresAppBuild: Int?
        /// 매니페스트 `event.windows`의 사본: 받기 전에 「곧 쓸 팩인가」를 가려 먼 팩의 큰 파일을 받지 않는다.
        public var windows: [SeasonPackManifest.Window]?
        public var updatedAt: String?
        public init(id: String, version: Int, archive: Archive? = nil, manifest: String? = nil, requiresAppBuild: Int? = nil, windows: [SeasonPackManifest.Window]? = nil, updatedAt: String? = nil) {
            self.id = id; self.version = version; self.archive = archive; self.manifest = manifest
            self.requiresAppBuild = requiresAppBuild; self.windows = windows; self.updatedAt = updatedAt
        }
    }

    public var format: String
    public var schema: Int
    public var packs: [Entry]

    /// 읽지 못하면 nil(받기를 그만두고 지금 팩을 그대로 쓴다).
    public static func decode(_ data: Data) -> SeasonPackIndex? {
        guard let index = try? JSONDecoder().decode(SeasonPackIndex.self, from: data),
              index.format == Self.format, index.schema == 1 else { return nil }
        return index
    }
}
