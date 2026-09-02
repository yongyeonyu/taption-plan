import Foundation

public enum ActivityPlaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case workplace
    case school
    case restaurant
    case other
}

public struct ActivityPlaceEvidence: Codable, Hashable, Sendable {
    public let span: ActivityTimeSpan
    public let registeredKind: ActivityPlaceKind?
    public let poiKind: ActivityPlaceKind?

    public init(span: ActivityTimeSpan, registeredKind: ActivityPlaceKind? = nil, poiKind: ActivityPlaceKind? = nil) {
        self.span = span
        self.registeredKind = registeredKind
        self.poiKind = poiKind
    }

    public var resolvedKind: ActivityPlaceKind? { registeredKind ?? poiKind }
}

public struct PlaceActivityInference: Codable, Hashable, Sendable {
    public let categoryID: String
    public let detailID: String
    public let confidence: Double
    public let provenance: ActivityDataProvenance

    public init(categoryID: String, detailID: String, confidence: Double, provenance: ActivityDataProvenance) {
        self.categoryID = categoryID
        self.detailID = detailID
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct PlaceActivityInferenceEngine: Sendable {
    public static let minimumStayDuration: TimeInterval = 15 * 60
    public let minimumStayDuration: TimeInterval

    public init(minimumStayDuration: TimeInterval = Self.minimumStayDuration) { self.minimumStayDuration = max(0, minimumStayDuration) }

    public func infer(_ evidence: ActivityPlaceEvidence) -> PlaceActivityInference? {
        guard evidence.span.duration >= minimumStayDuration, let kind = evidence.resolvedKind else { return nil }
        let category: String
        let detail: String
        switch kind {
        case .workplace: category = "work"; detail = "work.rest"
        case .school: category = "study"; detail = "study.rest"
        case .restaurant: category = "eating"; detail = "eating.meal"
        case .home: category = "activity"; detail = "activity.rest"
        case .other: category = "unconfirmed"; detail = "unconfirmed.automatic"
        }
        let confidence = evidence.registeredKind == nil ? 0.82 : 0.95
        return .init(categoryID: category, detailID: detail, confidence: confidence, provenance: .init(tier: .expected, status: ActivityAutomaticConfirmation.status(for: confidence), source: evidence.registeredKind == nil ? "poi-place-v1" : "registered-place-v1", evidence: [kind.rawValue, "15분 이상 체류"], confidence: confidence, span: evidence.span))
    }
}
