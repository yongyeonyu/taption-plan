import Foundation
import TaptionPlanCore

// `ActualSource`·`ConfidenceLevel`·`ActualLockReason`·`ActualRecord`는
// `TaptionPlanCore/Domain/ActualRecord.swift`에 있다.

extension ActualRecord {
    var semanticLevel: TimelineSemanticLevel {
        .activity
    }

    var sourceKind: TimelineSourceKind {
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
struct RecordLink: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var fromNodeID: String
    var toNodeID: String
    var createdAt: Date

    init(
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
