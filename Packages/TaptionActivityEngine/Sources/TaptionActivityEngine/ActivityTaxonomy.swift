import Foundation
import TaptionClassifierEngine

public struct ActivityDetailDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let behavior: String
    public let systemImage: String
    public let automaticOnly: Bool

    public init(id: String, title: String, behavior: String, systemImage: String, automaticOnly: Bool = false) {
        self.id = id
        self.title = title
        self.behavior = behavior
        self.systemImage = systemImage
        self.automaticOnly = automaticOnly
    }
}

public struct ActivityMajorDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let details: [ActivityDetailDefinition]

    public init(id: String, title: String, systemImage: String, details: [ActivityDetailDefinition]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.details = details
    }
}

public struct ActivityTaxonomy: Codable, Hashable, Sendable {
    public let version: Int
    public let majors: [ActivityMajorDefinition]

    public init(version: Int = 1, majors: [ActivityMajorDefinition]) {
        self.version = version
        self.majors = majors
    }

    /// 분류 패키지의 분류표(v3) 하나에서 만든다.
    public static let `default` = ActivityTaxonomy(classifier: .current)

    public init(classifier taxonomy: ClassifierTaxonomy) {
        self.init(version: taxonomy.version, majors: taxonomy.categories.map { category in
            ActivityMajorDefinition(id: category.id, title: category.title, systemImage: category.systemImage, details: category.details.map { detail in
                ActivityDetailDefinition(
                    id: detail.id, title: detail.title, behavior: detail.behavior, systemImage: detail.systemImage,
                    automaticOnly: detail.automaticOnly ?? category.automaticOnly ?? false
                )
            })
        })
    }

    public func major(for id: String) -> ActivityMajorDefinition? {
        majors.first { $0.id == id }
    }

    public func detail(for id: String) -> ActivityDetailDefinition? {
        majors.lazy.compactMap { major in major.details.first { $0.id == id } }.first
    }

    public func majorID(forDetailID id: String) -> String? {
        majors.first { major in major.details.contains { $0.id == id } }?.id
    }

    public func detail(majorID: String, behavior: String) -> ActivityDetailDefinition? {
        major(for: majorID)?.details.first { $0.behavior.caseInsensitiveCompare(behavior) == .orderedSame }
    }

    public static func major(_ id: String, title: String, systemImage: String, details: [ActivityDetailDefinition]) -> ActivityMajorDefinition {
        ActivityMajorDefinition(id: id, title: title, systemImage: systemImage, details: details)
    }

    public static func detail(_ id: String, title: String, behavior: String, systemImage: String, _ automaticOnly: Bool = false) -> ActivityDetailDefinition {
        ActivityDetailDefinition(id: id, title: title, behavior: behavior, systemImage: systemImage, automaticOnly: automaticOnly)
    }
}
