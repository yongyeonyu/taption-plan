import Foundation

/// `packs/season/index.json` — 배급 목록. 작아서 앱이 먼저 읽는다.
public struct SeasonPackIndex: Codable, Sendable, Equatable {
    public static let format = "bokki-season-packs"

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var version: Int
        public var manifest: String
        public var requiresAppBuild: Int?
        public var updatedAt: String?
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
