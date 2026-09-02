import Foundation

public enum ActivityDataTier: String, Codable, CaseIterable, Hashable, Sendable {
    case groundTruth
    case supporting
    case expected
}

public enum ActivityInferenceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case observed
    case expected
    case automaticallyConfirmed
    case userCorrected
    case unresolved
}

public struct ActivityDataProvenance: Codable, Hashable, Sendable {
    public let tier: ActivityDataTier
    public let status: ActivityInferenceStatus
    public let source: String
    public let evidence: [String]
    public let confidence: Double
    public let span: ActivityTimeSpan

    public init(tier: ActivityDataTier, status: ActivityInferenceStatus, source: String, evidence: [String] = [], confidence: Double, span: ActivityTimeSpan) {
        self.tier = tier
        self.status = status
        self.source = source
        self.evidence = evidence
        self.confidence = min(1, max(0, confidence))
        self.span = span
    }
}

public enum ActivityAutomaticConfirmation {
    public static let threshold = 0.80

    public static func status(for confidence: Double) -> ActivityInferenceStatus {
        confidence >= threshold ? .automaticallyConfirmed : .expected
    }
}
