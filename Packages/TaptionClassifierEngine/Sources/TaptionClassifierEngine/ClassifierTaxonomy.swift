import Foundation

/// 대분류·상세분류 표 하나. 앱·엔진·위젯이 같은 JSON(v3)을 읽는다.
public struct ClassifierTaxonomy: Codable, Hashable, Sendable {
    public struct Detail: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let behavior: String
        public let systemImage: String
        public let automaticOnly: Bool?

        public init(id: String, title: String, behavior: String, systemImage: String, automaticOnly: Bool? = nil) {
            self.id = id
            self.title = title
            self.behavior = behavior
            self.systemImage = systemImage
            self.automaticOnly = automaticOnly
        }
    }

    public struct Category: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let systemImage: String
        public let automaticOnly: Bool?
        public let details: [Detail]
    }

    public let version: Int
    public let categories: [Category]

    public static let current: ClassifierTaxonomy = load()

    public static func load() -> ClassifierTaxonomy {
        guard let url = Bundle.module.url(forResource: "record-classification", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ClassifierTaxonomy.self, from: data) else {
            return ClassifierTaxonomy(version: 0, categories: [])
        }
        return value
    }

    public var categoryIDs: [String] { categories.map(\.id) }

    public func category(_ id: String) -> Category? {
        categories.first { $0.id == id }
    }

    public func detail(categoryID: String, behavior: String) -> Detail? {
        category(categoryID)?.details.first { $0.behavior.caseInsensitiveCompare(behavior) == .orderedSame }
    }
}
