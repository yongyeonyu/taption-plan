import Foundation
import TaptionPlanCore

// `ActualSource`·`ConfidenceLevel`·`ActualLockReason`·`ActualRecord`는
// `TaptionPlanCore/Domain/ActualRecord.swift`에 있다.

extension ActualRecord {
    public var semanticLevel: TimelineSemanticLevel {
        .activity
    }

    public var sourceKind: TimelineSourceKind {
        switch source {
        case .manual, .timer:
            .action
        default:
            .automatic
        }
    }
}

/// A user-created relationship between two timeline records. The node IDs
/// use the stable prefixes emitted by `RecordRelationshipEngine`, allowing
/// calendar/place/travel records to be linked without changing their source
/// models.
public struct RecordLink: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fromNodeID: String
    public var toNodeID: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        fromNodeID: String,
        toNodeID: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.createdAt = createdAt
    }
}
