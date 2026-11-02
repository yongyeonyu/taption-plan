import Foundation
import TaptionPlanCore

enum ActualSource: String, Codable, CaseIterable, Sendable {
    case manual
    case timer
    case healthKit
    case appleWatch
    /// Passive iPhone Core Motion classification. These records are derived
    /// from the immutable motion history and are not user-editable.
    case motion
    case calendar
    case location
    case photo
    /// Playback observed while an AirPods route is connected.
    case media
    /// An active phone/FaceTime call observed through CallKit while an
    /// AirPods route is connected. CallKit does not expose call history.
    case call
    /// Screen Time usage reported through the Family Controls report.
    case appUsage
}

enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    init(score: Double) {
        switch score {
        case 0.75...:
            self = .high
        case 0.45..<0.75:
            self = .medium
        default:
            self = .low
        }
    }
}

/// 자동 기록이 잠긴 이유. `stability`는 분류 파이프라인이 바뀌면 풀리고, `user`는 사용자가 고친 것이다.
enum ActualLockReason: String, Codable, Hashable, Sendable { case stability, user }

struct ActualRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID?
    /// The routine context for an action/automatic record.  `planID` remains
    /// the concrete action or repeat segment; this second link keeps the
    /// routine and action layers independently addressable.
    var routineID: UUID?
    var title: String
    var categoryID: String
    var startedAt: Date
    var endedAt: Date?
    var source: ActualSource
    var confidence: ConfidenceLevel
    var createdAt: Date
    /// Optional provenance from the sensor-fusion pipeline.  These fields
    /// were added after the first archive format, so older records decode with
    /// their empty defaults and remain immutable.
    var behavior: String?
    var evidence: [String]
    var routeID: UUID?
    var sensorChunkID: UUID?
    var modelVersion: String?
    var manuallyCorrected: Bool
    /// Once an automatic major category has been stored, later sensor
    /// refreshes may extend its evidence but may not replace its category.
    /// Manual corrections remain the only override.
    var isClassificationLocked: Bool
    /// 분류 파이프라인의 사후 확률 평균(0…1). 예전 기록에는 없다.
    var classificationScore: Double?
    /// 예전 기록은 nil(안정 잠금으로 본다). 새 필드는 값이 있을 때만 써서 다시 저장해도 바이트가 같다.
    var lockReason: ActualLockReason?

    private enum CodingKeys: String, CodingKey {
        case id, planID, routineID, title, categoryID, startedAt, endedAt
        case source, confidence, createdAt, behavior, evidence, routeID
        case sensorChunkID, modelVersion, manuallyCorrected
        case isClassificationLocked, classificationScore, lockReason
    }

    init(
        id: UUID = UUID(),
        planID: UUID?,
        routineID: UUID? = nil,
        title: String,
        categoryID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        source: ActualSource,
        confidence: ConfidenceLevel = .high,
        createdAt: Date = .now,
        behavior: String? = nil,
        evidence: [String] = [],
        routeID: UUID? = nil,
        sensorChunkID: UUID? = nil,
        modelVersion: String? = nil,
        manuallyCorrected: Bool = false,
        isClassificationLocked: Bool? = nil,
        classificationScore: Double? = nil,
        lockReason: ActualLockReason? = nil
    ) {
        self.id = id
        self.planID = planID
        self.routineID = routineID
        self.title = title
        self.categoryID = categoryID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
        self.behavior = behavior
        self.evidence = evidence
        self.routeID = routeID
        self.sensorChunkID = sensorChunkID
        self.modelVersion = modelVersion
        self.manuallyCorrected = manuallyCorrected
        self.isClassificationLocked = isClassificationLocked
            ?? source.usesAutomaticClassification
        self.classificationScore = classificationScore
        self.lockReason = lockReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        planID = try values.decodeIfPresent(UUID.self, forKey: .planID)
        routineID = try values.decodeIfPresent(UUID.self, forKey: .routineID)
        title = try values.decode(String.self, forKey: .title)
        categoryID = try values.decode(String.self, forKey: .categoryID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        source = try values.decode(ActualSource.self, forKey: .source)
        confidence = try values.decode(ConfidenceLevel.self, forKey: .confidence)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        behavior = try values.decodeIfPresent(String.self, forKey: .behavior)
        evidence = try values.decodeIfPresent([String].self, forKey: .evidence) ?? []
        routeID = try values.decodeIfPresent(UUID.self, forKey: .routeID)
        sensorChunkID = try values.decodeIfPresent(UUID.self, forKey: .sensorChunkID)
        modelVersion = try values.decodeIfPresent(String.self, forKey: .modelVersion)
        manuallyCorrected = try values.decodeIfPresent(Bool.self, forKey: .manuallyCorrected) ?? false
        isClassificationLocked = try values.decodeIfPresent(Bool.self, forKey: .isClassificationLocked)
            ?? source.usesAutomaticClassification
        classificationScore = try values.decodeIfPresent(Double.self, forKey: .classificationScore)
        lockReason = try values.decodeIfPresent(ActualLockReason.self, forKey: .lockReason)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(planID, forKey: .planID)
        try values.encodeIfPresent(routineID, forKey: .routineID)
        try values.encode(title, forKey: .title)
        try values.encode(categoryID, forKey: .categoryID)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encode(source, forKey: .source)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(behavior, forKey: .behavior)
        try values.encode(evidence, forKey: .evidence)
        try values.encodeIfPresent(routeID, forKey: .routeID)
        try values.encodeIfPresent(sensorChunkID, forKey: .sensorChunkID)
        try values.encodeIfPresent(modelVersion, forKey: .modelVersion)
        try values.encode(manuallyCorrected, forKey: .manuallyCorrected)
        try values.encode(isClassificationLocked, forKey: .isClassificationLocked)
        try values.encodeIfPresent(classificationScore, forKey: .classificationScore)
        try values.encodeIfPresent(lockReason, forKey: .lockReason)
    }

    func span(asOf date: Date = .now) -> TimeSpan {
        guard startedAt < date else {
            return TimeSpan(start: startedAt, end: startedAt)
        }
        let observedEnd = min(endedAt ?? date, date)
        return TimeSpan(start: startedAt, end: max(startedAt, observedEnd))
    }
}

extension ActualSource {
    var usesAutomaticClassification: Bool {
        switch self {
        case .manual, .timer, .calendar, .photo:
            false
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        }
    }
}

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
